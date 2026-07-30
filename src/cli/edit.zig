//! `mox edit <name>`: open the source file behind a managed path in `$EDITOR`.
//!
//! `<name>` is a live path: absolute, `~`-relative, or relative to the current
//! directory. With no `--axis`, the base source file is edited; `--axis
//! <tuple>` selects the matching overlay (Cat A/C) or region fragment (Cat B)
//! instead. Read-only wrt mox state: takes no lock. When the requested source
//! does not exist, the candidate paths are reported.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");
const env_mod = @import("env");

const Io = std.Io;
const Env = env_mod.Env;
const AxisTuple = mox.source.tree.AxisTuple;

/// Why a `<name>` names no live path. Separate from the allocation failure
/// every caller propagates, so `reportTarget` can render each case.
pub const TargetFailure = error{
    UnsupportedTilde,
    NoCwd,
    NoHomeDir,
};

pub const TargetError = TargetFailure || error{OutOfMemory};

/// Canonical absolute live path a `<name>` refers to.
///
/// `~` and `~/x` expand against the environment's home -- a shell expands
/// those itself, but a quoted `"~/x"`, a PowerShell argument to a native
/// executable, and a non-shell caller all deliver the tilde verbatim. Every
/// other name is a filesystem path: used as given when absolute, resolved
/// against `cwd` when not. `.` and `..` are resolved, so `../fish/config.fish`
/// names from `~/.config/nvim` what it names in a shell, and a spelling
/// carrying either segment still equals the live path the source walk derived.
///
/// `cwd` is null when the process has no readable current directory: a
/// relative name is then unresolvable, an absolute or `~` one is unaffected.
pub fn liveTarget(
    arena: std.mem.Allocator,
    env: Env,
    cwd: ?[]const u8,
    name: []const u8,
) TargetError![]const u8 {
    const expanded = try env_mod.dirs.expandTilde(arena, env, name);
    // expandTilde passes `~user/x` -- and, on Windows, `~\x` -- through
    // untouched. Resolving either would silently name a directory whose first
    // component is a literal `~`, so neither reaches the filesystem.
    if (expanded.len > 0 and expanded[0] == '~') return error.UnsupportedTilde;
    if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(arena, &.{expanded});
    return std.fs.path.resolve(arena, &.{ cwd orelse return error.NoCwd, expanded });
}

/// Print why `name` names no live path, and return the exit code the caller
/// returns. `cmd` is the command's own prefix, e.g. `mox add`.
pub fn reportTarget(w: *Io.Writer, cmd: []const u8, name: []const u8, err: TargetFailure) !u8 {
    const why = switch (err) {
        error.UnsupportedTilde => if (std.mem.startsWith(u8, name, "~\\"))
            "'~\\' is not expanded -- use '~/' or an absolute path"
        else
            "'~user' is not supported -- use an absolute path",
        error.NoCwd => "not absolute, and the current directory could not be read",
        error.NoHomeDir => "cannot expand '~': neither HOME nor USERPROFILE is set",
    };
    try w.print("{s}: {s}: {s}\n", .{ cmd, name, why });
    return 1;
}

/// Render an axis tuple to its canonical filename form: pairs sorted by name
/// (parseFilename already sorts), joined by `+`, e.g. `os=darwin+profile=work`.
pub fn tupleFilename(arena: std.mem.Allocator, tuple: AxisTuple) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (tuple.pairs, 0..) |p, i| {
        if (i > 0) try w.writeByte('+');
        try w.print("{s}={s}", .{ p.name, p.value });
    }
    return aw.toOwnedSlice();
}

/// True when two axis tuples bind exactly the same (name, value) pairs. Both
/// are sorted by name (parseFilename guarantees it), so a positional compare
/// suffices.
pub fn tuplesEqual(a: AxisTuple, b: AxisTuple) bool {
    if (a.pairs.len != b.pairs.len) return false;
    for (a.pairs, b.pairs) |pa, pb| {
        if (!std.mem.eql(u8, pa.name, pb.name)) return false;
        if (!std.mem.eql(u8, pa.value, pb.value)) return false;
    }
    return true;
}

const Spec = struct {
    name: cli.Pos([]const u8, .{ .help = "managed live path (absolute, ~-relative, or relative to the current directory)" }),
    axis: cli.Opt([]const u8, .{ .value_name = "tuple", .help = "edit the overlay/fragment for this axis tuple instead" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const name = a.name;
    const axis_str: ?[]const u8 = a.axis;
    const live_path = liveTarget(ctx.alloc, context.env, context.cwd, name) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => |f| return reportTarget(ctx.err, "mox edit", name, f),
    };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, context.paths.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox edit: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };

    var found: ?mox.source.tree.ManagedFile = null;
    for (tree.files) |f| {
        if (std.mem.eql(u8, f.live_path, live_path)) {
            found = f;
            break;
        }
    }

    const target_path: []const u8 = blk: {
        const file = found orelse {
            // Not managed: report where a base file would live.
            const rel = std.mem.trimStart(u8, live_path[@min(context.paths.home.len, live_path.len)..], "/");
            const cand = try std.fs.path.join(ctx.alloc, &.{ src_dir, rel });
            try ctx.err.print("mox edit: {s}: not managed (no source at {s})\n", .{ name, cand });
            return 1;
        };

        if (axis_str) |as| {
            const want = mox.source.tuple.parseFilename(ctx.alloc, as) catch {
                try ctx.err.print("mox edit: invalid axis tuple '{s}'\n", .{as});
                return 2;
            };
            if (overlayFor(file, want)) |p| break :blk p;
            const tuple_name = try tupleFilename(ctx.alloc, want);
            const base_abs = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, file.source_base_path });
            const overlay_dir = try std.fmt.allocPrint(ctx.alloc, "{s}.d", .{base_abs});
            const cand = try mox.source.path.joinKeyOnto(ctx.alloc, overlay_dir, tuple_name);
            try ctx.err.print("mox edit: no overlay for '{s}' on {s} (looked for {s})\n", .{ as, name, cand });
            return 1;
        }

        if (!file.has_base) {
            try ctx.err.print("mox edit: {s} has no base file; pass --axis <tuple> to edit an overlay\n", .{name});
            return 1;
        }
        break :blk file.source_base_abs;
    };

    return editFile(ctx, target_path);
}

/// Absolute path of the overlay (Cat A/C) or region fragment (Cat B) on `file`
/// whose tuple equals `want`, or null when none matches.
fn overlayFor(file: mox.source.tree.ManagedFile, want: AxisTuple) ?[]const u8 {
    for (file.overlays) |ov| {
        if (tuplesEqual(ov.tuple, want)) return ov.path;
    }
    for (file.regions) |region| {
        for (region.fragments) |frag| {
            if (tuplesEqual(frag.tuple, want)) return frag.path;
        }
    }
    return null;
}

/// Spawn `$EDITOR <path>` inheriting the terminal, and wait for it. `$EDITOR`
/// may carry arguments (e.g. `code -w`), split on whitespace.
fn editFile(ctx: *app.Ctx, path: []const u8) !u8 {
    const context = ctx.context.?;
    const editor = context.env.getAlloc(ctx.alloc, "EDITOR") catch {
        try ctx.err.writeAll("mox edit: $EDITOR is not set\n");
        return 1;
    };
    if (editor.len == 0) {
        try ctx.err.writeAll("mox edit: $EDITOR is empty\n");
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, editor, ' ');
    while (it.next()) |word| try argv.append(ctx.alloc, word);
    try argv.append(ctx.alloc, path);

    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        try ctx.err.print("mox edit: cannot launch editor '{s}': {s}\n", .{ editor, @errorName(e) });
        return 1;
    };
    const term = child.wait(ctx.io) catch |e| {
        try ctx.err.print("mox edit: editor wait failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub const command = app.command(Spec, .{
    .name = "edit",
    .summary = "Open the source behind a managed path in $EDITOR",
    .usage = "mox edit <name> [--axis <tuple>]",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

/// A home root that is absolute on the HOST. `std.fs.path.isAbsolute` is
/// platform-specific -- `/home/me` is not absolute on Windows, so a POSIX-only
/// literal would take the cwd-relative branch there and resolve to nothing.
const test_home = if (@import("builtin").os.tag == .windows) "C:\\home\\me" else "/home/me";

fn testEnv(a: std.mem.Allocator, home: []const u8) !Env {
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    try map.put("HOME", home);
    return .{ .map = map };
}

test "liveTarget: an absolute name is used as given, a relative one resolves against cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try testEnv(a, test_home);

    const zshrc = try std.fs.path.join(a, &.{ test_home, ".zshrc" });
    try testing.expectEqualStrings(zshrc, try liveTarget(a, env, null, zshrc));

    // The same name means different files from different directories.
    const nvim = try std.fs.path.join(a, &.{ test_home, ".config", "nvim" });
    const fish = try std.fs.path.join(a, &.{ test_home, ".config", "fish" });
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ nvim, "init.lua" }),
        try liveTarget(a, env, nvim, "init.lua"),
    );
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ fish, "init.lua" }),
        try liveTarget(a, env, fish, "init.lua"),
    );
}

test "liveTarget: `.` and `..` resolve, so a spelling still equals the walked live path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try testEnv(a, test_home);
    const nvim = try std.fs.path.join(a, &.{ test_home, ".config", "nvim" });

    const init_lua = try std.fs.path.join(a, &.{ nvim, "init.lua" });
    try testing.expectEqualStrings(init_lua, try liveTarget(a, env, nvim, "./init.lua"));
    try testing.expectEqualStrings(init_lua, try liveTarget(a, env, nvim, "init.lua"));

    // `..` reaches a sibling config directory, as it does in a shell.
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ test_home, ".config", "fish", "config.fish" }),
        try liveTarget(a, env, nvim, "../fish/config.fish"),
    );

    // A `./`-spelled absolute name canonicalizes to its plain spelling.
    const dotted = try std.fs.path.join(a, &.{ test_home, ".config", ".", "app.conf" });
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ test_home, ".config", "app.conf" }),
        try liveTarget(a, env, null, dotted),
    );
}

test "liveTarget: `~` and `~/x` expand against the environment's home" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try testEnv(a, test_home);
    // cwd is null throughout: a tilde name never consults it.
    try testing.expectEqualStrings(test_home, try liveTarget(a, env, null, "~"));
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ test_home, ".config", "nvim", "init.lua" }),
        try liveTarget(a, env, null, "~/.config/nvim/init.lua"),
    );
}

test "liveTarget: an unexpandable tilde is refused rather than resolved as a directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try testEnv(a, test_home);

    // `~other/x` and `~\x` would otherwise name a directory literally called
    // `~other` or `~` under cwd.
    try testing.expectError(error.UnsupportedTilde, liveTarget(a, env, test_home, "~other/.zshrc"));
    try testing.expectError(error.UnsupportedTilde, liveTarget(a, env, test_home, "~\\.zshrc"));

    // A file whose name merely starts with `~` stays reachable, spelled as the
    // relative path it is.
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ test_home, "~backup" }),
        try liveTarget(a, env, test_home, "./~backup"),
    );
}

test "liveTarget: a relative name needs a cwd, a tilde or absolute one does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try testEnv(a, test_home);
    try testing.expectError(error.NoCwd, liveTarget(a, env, null, ".zshrc"));

    var empty = std.process.Environ.Map.init(a);
    const homeless: Env = .{ .map = &empty };
    try testing.expectError(error.NoHomeDir, liveTarget(a, homeless, test_home, "~/.zshrc"));
    // No home needed when no tilde is involved.
    const zshrc = try std.fs.path.join(a, &.{ test_home, ".zshrc" });
    try testing.expectEqualStrings(zshrc, try liveTarget(a, homeless, test_home, ".zshrc"));
}

test "tupleFilename: renders sorted pairs joined by plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try mox.source.tuple.parseFilename(arena.allocator(), "profile=work+os=darwin");
    try testing.expectEqualStrings("os=darwin+profile=work", try tupleFilename(arena.allocator(), t));
}

test "tuplesEqual: same pairs match, differing pairs do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try mox.source.tuple.parseFilename(a, "os=darwin");
    const y = try mox.source.tuple.parseFilename(a, "os=darwin");
    const z = try mox.source.tuple.parseFilename(a, "os=linux");
    try testing.expect(tuplesEqual(x, y));
    try testing.expect(!tuplesEqual(x, z));
}
