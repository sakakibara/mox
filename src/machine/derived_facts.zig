//! `data/facts.toml` (repo layer, private-shadowed): rows that derive a
//! single-value machine fact from an environment variable override or a
//! filesystem candidate search -- the registry that replaced capture's
//! hardcoded brew/cargo/go/pnpm detection (D8). It pairs with the
//! machine-local `$XDG_CONFIG_HOME/mox/facts.toml` (`facts.zig`): repo
//! DERIVES, machine STATES, same noun because same concept.

const std = @import("std");
const toml = @import("../data/toml.zig");
const data_source = @import("../data/source.zig");
const data_value = @import("../data/value.zig");
const source_axes = @import("../source/axes.zig");
const source_tuple = @import("../source/tuple.zig");
const diag_mod = @import("diag.zig");
const state_mod = @import("state.zig");

const Io = std.Io;
const Environ = @import("env").Env;

pub const Diag = diag_mod.Diag;

pub const LoadResult = struct {
    facts: []const state_mod.Fact = &.{},
};

/// Load and resolve every row of `data/facts.toml`'s `[[facts]]` array.
/// Missing file (in both private and repo layers, or `repo_dir` itself
/// empty) is not an error: returns no facts. A malformed row (bad `name`
/// charset, wrong field type) or a row whose `name` collides with a
/// built-in fact or a reserved axis name is `error.MalformedFactsRow` /
/// `error.ReservedFactsRowName`, with `diag` (when non-null) naming the row.
pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    repo_dir: []const u8,
    private_dir: []const u8,
    home: []const u8,
    diag: ?*Diag,
) !LoadResult {
    const content = (try data_source.readShadowed(arena, io, repo_dir, private_dir, "facts.toml")) orelse
        return .{};

    const array_map = toml.parse(arena, content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedFactsRow,
    };
    const rows = array_map.get("facts") orelse return .{};

    var facts: std.ArrayList(state_mod.Fact) = .empty;
    var seen = std.StringHashMap(void).init(arena);

    for (rows, 0..) |row, i| {
        const name = nameOf(row) orelse {
            if (diag) |d| d.set("data/facts.toml: row {d} has no string \"name\"", .{i});
            return error.MalformedFactsRow;
        };
        if (!isValidFactCharset(name)) {
            if (diag) |d| d.set("data/facts.toml: row {d}: \"{s}\" is not a valid fact name", .{ i, name });
            return error.MalformedFactsRow;
        }
        if (source_axes.isReservedAxisName(name) or state_mod.isBuiltinField(name)) {
            if (diag) |d| d.set("data/facts.toml: \"{s}\" collides with a reserved axis or built-in fact name", .{name});
            return error.ReservedFactsRowName;
        }
        if (seen.contains(name)) {
            if (diag) |d| d.set("data/facts.toml: \"{s}\" is declared more than once", .{name});
            return error.ReservedFactsRowName;
        }
        try seen.put(name, {});

        const env_field = row.get("env");
        if (env_field != null and env_field.? != .string) {
            if (diag) |d| d.set("data/facts.toml: row \"{s}\": \"env\" must be a string", .{name});
            return error.MalformedFactsRow;
        }
        const candidates_field = row.get("candidates");
        if (candidates_field != null and candidates_field.? != .array_of_strings) {
            if (diag) |d| d.set("data/facts.toml: row \"{s}\": \"candidates\" must be an array of strings", .{name});
            return error.MalformedFactsRow;
        }

        const value = try resolveRow(arena, io, environ, home, env_field, candidates_field) orelse continue;
        try facts.append(arena, .{ .name = try arena.dupe(u8, name), .value = value });
    }

    return .{ .facts = try facts.toOwnedSlice(arena) };
}

fn nameOf(row: toml.Record) ?[]const u8 {
    const v = row.get("name") orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// The fact-name charset: lowercase letter, then lowercase alnum/underscore --
/// the same grammar `source.tuple`'s axis names use.
fn isValidFactCharset(name: []const u8) bool {
    return source_tuple.isValidAxisName(name);
}

/// Resolve one row to its bound value, or null when nothing exists.
/// `env`, when set to a non-empty value naming an EXISTING directory, wins
/// outright. Otherwise each `candidates` entry (`~` expanded to `home`) is
/// tried in order; the first that exists on disk binds the fact.
fn resolveRow(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    home: []const u8,
    env_field: ?data_value.Value,
    candidates_field: ?data_value.Value,
) !?[]const u8 {
    if (env_field) |ev| {
        const name = ev.string;
        if (name.len > 0) {
            const v = environ.getAlloc(arena, name) catch null;
            if (v) |val| {
                if (val.len > 0 and dirExists(io, val)) return val;
            }
        }
    }
    if (candidates_field) |cv| {
        for (cv.array_of_strings) |c| {
            const expanded = try expandTilde(arena, c, home);
            if (dirExists(io, expanded)) return expanded;
        }
    }
    return null;
}

/// True when `path` exists AND resolves to a directory (symlinks followed --
/// the default): a regular file candidate must never bind a directory fact.
fn dirExists(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `~` expands to `home`; `~/rest` expands to `<home>/rest` (native join);
/// anything else passes through verbatim.
fn expandTilde(arena: std.mem.Allocator, candidate: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, candidate, "~")) return home;
    if (std.mem.startsWith(u8, candidate, "~/")) {
        return std.fs.path.join(arena, &.{ home, candidate[2..] });
    }
    return candidate;
}

test "load: missing file returns no facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = std.process.Environ.Map.init(a);
    const r = try load(a, std.testing.io, .{ .map = &map }, "", "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 0), r.facts.len);
}

test "load: env override wins when it names an existing dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "custom");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"brew_prefix\"\nenv = \"HOMEBREW_PREFIX\"\ncandidates = [\"/opt/homebrew\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const custom = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "custom" });

    var map = std.process.Environ.Map.init(a);
    try map.put("HOMEBREW_PREFIX", custom);
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings("brew_prefix", r.facts[0].name);
    try std.testing.expectEqualStrings(custom, r.facts[0].value);
}

test "load: empty env falls through to candidates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "cand");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"brew_prefix\"\nenv = \"HOMEBREW_PREFIX\"\ncandidates = [\"__CAND__\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const cand = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cand" });

    // Rewrite the candidate to the real absolute path (TOML has no
    // interpolation of its own; substitute after writing). A TOML literal
    // (single-quoted) string, not a basic one: a native Windows path embeds
    // backslashes, which a basic string's escape grammar would reject.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"brew_prefix\"\nenv = \"HOMEBREW_PREFIX\"\ncandidates = ['{s}']\n", .{cand}),
    });

    var map = std.process.Environ.Map.init(a);
    try map.put("HOMEBREW_PREFIX", "");
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings(cand, r.facts[0].value);
}

test "load: no candidate exists leaves the row unbound, no error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"brew_prefix\"\ncandidates = [\"/definitely/does/not/exist\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 0), r.facts.len);
}

test "load: a candidate naming a regular file does not bind (directory required)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "not_a_dir", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"brew_prefix\"\ncandidates = [\"__CAND__\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const file_cand = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "not_a_dir" });

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"brew_prefix\"\ncandidates = ['{s}']\n", .{file_cand}),
    });

    var map = std.process.Environ.Map.init(a);
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 0), r.facts.len);
}

test "load: a symlink to a directory candidate binds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "real_dir");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const real_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "real_dir" });
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "dir_link" });

    try Io.Dir.cwd().symLink(io, real_dir, link, .{ .is_directory = true });

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"brew_prefix\"\ncandidates = ['{s}']\n", .{link}),
    });

    var map = std.process.Environ.Map.init(a);
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings(link, r.facts[0].value);
}

test "load: an env override naming a regular file does not win, falls through to candidates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "cand");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const cand = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cand" });
    const file_override = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "override_file" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_override, .data = "" });

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"brew_prefix\"\nenv = \"HOMEBREW_PREFIX\"\ncandidates = ['{s}']\n", .{cand}),
    });

    var map = std.process.Environ.Map.init(a);
    try map.put("HOMEBREW_PREFIX", file_override);
    const r = try load(a, io, .{ .map = &map }, repo, "", "/home/x", null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings(cand, r.facts[0].value);
}

test "load: ~ expands to home in a candidate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "home/.cargo");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"cargo_home\"\ncandidates = [\"~/.cargo\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const want = try std.fs.path.join(a, &.{ home, ".cargo" });

    var map = std.process.Environ.Map.init(a);
    const r = try load(a, io, .{ .map = &map }, repo, "", home, null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings(want, r.facts[0].value);
}

test "load: a row named for a reserved axis is a capture error naming the row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"path\"\ncandidates = [\"/tmp\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    var d: Diag = .{};
    try std.testing.expectError(error.ReservedFactsRowName, load(a, io, .{ .map = &map }, repo, "", "/home/x", &d));
    try std.testing.expect(std.mem.indexOf(u8, d.capture().?, "path") != null);
}

test "load: a row named for a built-in field is a capture error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"home\"\ncandidates = [\"/tmp\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    try std.testing.expectError(error.ReservedFactsRowName, load(a, io, .{ .map = &map }, repo, "", "/home/x", null));
}

test "load: two rows with the same name is a capture error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"gopath\"\ncandidates = [\"/tmp\"]\n\n[[facts]]\nname = \"gopath\"\ncandidates = [\"/tmp\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    try std.testing.expectError(error.ReservedFactsRowName, load(a, io, .{ .map = &map }, repo, "", "/home/x", null));
}

test "load: a row with no name is a malformed-row capture error naming the row index" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\ncandidates = [\"/tmp\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    var d: Diag = .{};
    try std.testing.expectError(error.MalformedFactsRow, load(a, io, .{ .map = &map }, repo, "", "/home/x", &d));
    try std.testing.expect(std.mem.indexOf(u8, d.capture().?, "row 0") != null);
}

test "load: candidates given as a bare string (not an array) is malformed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = "[[facts]]\nname = \"gopath\"\ncandidates = \"/tmp\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    try std.testing.expectError(error.MalformedFactsRow, load(a, io, .{ .map = &map }, repo, "", "/home/x", null));
}

test "load: private layer shadows repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "private/data");
    try tmp.dir.createDirPath(io, "repo-cand");
    try tmp.dir.createDirPath(io, "priv-cand");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const priv = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "private" });
    const repo_cand = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo-cand" });
    const priv_cand = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "priv-cand" });

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"x\"\ncandidates = ['{s}']\n", .{repo_cand}),
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "private/data/facts.toml",
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"x\"\ncandidates = ['{s}']\n", .{priv_cand}),
    });

    var map = std.process.Environ.Map.init(a);
    const r = try load(a, io, .{ .map = &map }, repo, priv, "/home/x", null);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings(priv_cand, r.facts[0].value);
}
