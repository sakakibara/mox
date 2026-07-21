const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Io = std.Io;

pub const Outcome = enum {
    added,
    not_found,
    outside_home,
    is_home,
    is_directory,
    already_managed,
    into_overlay_dir,
};

/// True when the target key names a file directly inside a `<base>.d/` overlay
/// directory (its parent segment ends in `.d`). mox reserves those directories
/// for axis overlays and fragments, so writing a captured file there would make
/// the tree walk misread it as an overlay of `<base>` -- refuse instead.
fn intoOverlayDir(key: []const u8) bool {
    const parent = std.fs.path.dirnamePosix(key) orelse return false;
    const last = std.fs.path.basenamePosix(parent);
    return std.mem.endsWith(u8, last, ".d");
}

pub const Result = struct {
    outcome: Outcome,
    /// Absolute source path (valid for `.added` and `.already_managed`).
    src_path: []const u8 = "",
};

/// True when `live_path` names HOME itself (ignoring a trailing separator),
/// which `relUnder` reports as null just like a path outside HOME.
fn isHomeItself(live_path: []const u8, home: []const u8) bool {
    const l = std.mem.trimEnd(u8, live_path, "/\\");
    const h = std.mem.trimEnd(u8, home, "/\\");
    return std.mem.eql(u8, l, h);
}

/// Copy one live file into `src/` as a base file. Returns an Outcome the
/// caller renders. Junk filtering and recursion are the caller's concern (see
/// add-tree). A mode git cannot carry (not 0644/0755) is recorded in
/// `.mox/attributes.toml` so it survives a clone. A live symlink is captured as
/// a regular source file whose content is the link target, flagged there too.
/// `seed_once` records the explicit seed-once intent for this target.
pub fn addFile(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    seed_once: bool,
) !Result {
    // lstat, not stat: a live symlink is captured as such, never followed.
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .{ .outcome = .not_found },
        else => return e,
    };
    // Single-file add refuses a directory (use add-tree to recurse); reading one
    // would otherwise surface a raw IsDir error.
    if (st.kind == .directory) return .{ .outcome = .is_directory };

    // Boundary-aware home membership, matching the attribute key derivation
    // (relUnder): a raw startsWith would let `/home/me` swallow `/home/meadow`,
    // and the recorded key and the add path would then disagree. `relUnder`
    // returns null for HOME itself, so detect that separately.
    const trimmed = if (try mox.source.path.liveKeyUnderHome(arena, home, live_path)) |rel|
        rel
    else if (isHomeItself(live_path, home))
        return .{ .outcome = .is_home }
    else
        return .{ .outcome = .outside_home };

    // A key with a `..` segment (relUnder matches HOME textually and does not
    // normalize) would resolve outside src/ once joined -- refuse the escape.
    if (mox.source.path.keyEscapes(trimmed)) return .{ .outcome = .outside_home };
    // A file inside a `<base>.d/` directory would be misread as an overlay.
    if (intoOverlayDir(trimmed)) return .{ .outcome = .into_overlay_dir };

    const src_path = try std.fs.path.join(arena, &.{ repo_dir, "src", trimmed });

    if (Io.Dir.cwd().access(io, src_path, .{})) |_| {
        return .{ .outcome = .already_managed, .src_path = src_path };
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    if (std.fs.path.dirname(src_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    // A live symlink: write its target string as the source content (a regular
    // file, so no symlink enters the repo) and record `symlink = true`.
    if (st.kind == .sym_link) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try Io.Dir.cwd().readLink(io, live_path, &buf);
        try mox.apply.write.writeAtomic(io, src_path, buf[0..n], 0o644);
        try recordAttrs(arena, io, repo_dir, home, live_path, .{ .symlink = true, .seed_once = seed_once });
        return .{ .outcome = .added, .src_path = src_path };
    }

    const content = try Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024));
    // Write the source with the live file's mode so git carries the exec bit
    // (100755) natively -- otherwise an added executable would land at the
    // umask default and lose +x on the next clone.
    const mode = mox.apply.write.modeOf(st.permissions);
    try mox.apply.write.writeAtomic(io, src_path, content, mode);

    // Record whatever git cannot carry: a mode that is not 0644/0755 (those
    // travel via git+stat), and the explicit seed-once intent. Keyed by the
    // portable home-relative key, never the native path.
    const recorded_mode: ?u32 = if (mode != 0o644 and mode != 0o755) mode else null;
    try recordAttrs(arena, io, repo_dir, home, live_path, .{ .mode = recorded_mode, .seed_once = seed_once });
    return .{ .outcome = .added, .src_path = src_path };
}

/// Merge `fields` into the target's `.mox/attributes.toml` entry (loading the
/// existing record so a mode/symlink/seed-once capture never clobbers another),
/// then persist. A no-op when `fields` records nothing.
fn recordAttrs(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    fields: mox.source.attributes.Entry,
) !void {
    if (fields.mode == null and !fields.symlink and !fields.seed_once) return;
    const key = try mox.source.path.liveKeyRelToHome(arena, home, live_path);
    var attrs = try mox.source.attributes.load(arena, io, repo_dir);
    var entry = attrs.lookup(key) orelse mox.source.attributes.Entry{};
    if (fields.mode) |m| entry.mode = m;
    if (fields.symlink) entry.symlink = true;
    if (fields.seed_once) entry.seed_once = true;
    try attrs.set(key, entry);
    try attrs.write(io, repo_dir);
}

const Spec = struct {
    path: cli.spec.Pos([]const u8, .{ .help = "live file to start managing" }),
    seed_once: cli.spec.Flag(.{ .help = "seed the target once; never overwrite an existing one" }),
    force: cli.spec.Flag(.{ .help = "add even if the path matches an ignore rule" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const live_path = a.path;
    const home = context.env.getAlloc(ctx.alloc, "HOME") catch {
        try ctx.err.writeAll("mox add: HOME not set\n");
        return 1;
    };

    if (!a.force) {
        const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
        var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, live_path);
        const is_dir = if (Io.Dir.cwd().statFile(ctx.io, live_path, .{ .follow_symlinks = false })) |st|
            st.kind == .directory
        else |_|
            false;
        if (ruleset.isPathIgnored(rel, is_dir)) {
            try ctx.err.print("mox add: {s} matches an ignore rule; use --force to add it anyway\n", .{rel});
            return 1;
        }
    }

    const result = try addFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, live_path, a.seed_once);
    switch (result.outcome) {
        .added => {
            try ctx.out.print("Added {s} -> {s}\n", .{ live_path, result.src_path });
            if (mox.source.ignore.load.looksLikeSecret(std.fs.path.basename(live_path))) {
                try ctx.out.print("  note: {s} looks like a secret and will be committed\n", .{live_path});
            }
            // Rebuild the coupling graph so the new file's tokens can couple
            // with existing sources on the next commit.
            buildInitialCoupling(ctx) catch {};
            return 0;
        },
        .not_found => {
            try ctx.err.print("mox add: {s}: not found\n", .{live_path});
            return 1;
        },
        .outside_home => {
            try ctx.err.print("mox add: {s}: outside HOME ({s})\n", .{ live_path, home });
            return 1;
        },
        .is_home => {
            try ctx.err.writeAll("mox add: cannot add HOME itself\n");
            return 1;
        },
        .is_directory => {
            try ctx.err.print("mox add: {s}: is a directory (use 'mox add-tree' to add its contents)\n", .{live_path});
            return 1;
        },
        .already_managed => {
            try ctx.err.print("mox add: {s}: already managed (source at {s})\n", .{ live_path, result.src_path });
            return 1;
        },
        .into_overlay_dir => {
            try ctx.err.print("mox add: {s}: sits in a '.d/' overlay directory, which mox reserves for axis overlays\n", .{live_path});
            return 1;
        },
    }
}

pub const command = app.command(Spec, .{
    .name = "add",
    .summary = "Start managing a live file as a base file in src/",
    .usage = "mox add [--seed-once] <path>",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "addFile: a directory is rejected with is_directory, not a raw error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    try tmp.dir.createDirPath(io, "home/adir");
    const adir = try std.fs.path.join(a, &.{ home, "adir" });

    const r = try addFile(a, io, repo, home, adir, false);
    try testing.expectEqual(Outcome.is_directory, r.outcome);

    // A regular file under home still adds.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const afile = try std.fs.path.join(a, &.{ home, ".zshrc" });
    const ok = try addFile(a, io, repo, home, afile, false);
    try testing.expectEqual(Outcome.added, ok.outcome);
}

test "addFile: a sibling dir sharing a home prefix is outside_home, not mis-keyed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    // home is `.../me`; `.../meadow` merely shares the `me` prefix and must not
    // be treated as under home (a raw startsWith would wrongly accept it).
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "me" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    try tmp.dir.createDirPath(io, "meadow");
    try tmp.dir.writeFile(io, .{ .sub_path = "meadow/x", .data = "hi\n" });
    const sibling = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "meadow", "x" });

    const r = try addFile(a, io, repo, home, sibling, false);
    try testing.expectEqual(Outcome.outside_home, r.outcome);
}

test "addFile: a '..' path that escapes the source tree is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    // A real file OUTSIDE home, reachable from home only via `..`. home must
    // exist for the kernel to resolve the `..` back down to root/secret.
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "outside\n" });
    const escape = try std.fs.path.join(a, &.{ home, "..", "secret" });

    // The path stats fine (it resolves to root/secret), but its derived key
    // carries `..` and must be refused rather than captured outside src/.
    const r = try addFile(a, io, repo, home, escape, false);
    try testing.expectEqual(Outcome.outside_home, r.outcome);
}

const builtin = @import("builtin");

fn chmod(path: []const u8, mode: u32) void {
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), @intCast(mode));
}

test "addFile: a restrictive mode is recorded in attributes; 0644/0755 are not" {
    // The captured mode comes from the live file's native bits; a filesystem
    // without them cannot express 0600/0755 and there is nothing to record.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    // A 0600 live file: its mode is recorded.
    try tmp.dir.createDirPath(io, "home/.ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.ssh/config", .data = "Host x\n" });
    const priv = try std.fs.path.join(a, &.{ home, ".ssh", "config" });
    chmod(priv, 0o600);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, priv, false)).outcome);

    // A 0755 live file: git+stat carry it, so nothing is recorded.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/tool", .data = "#!/bin/sh\n" });
    const tool = try std.fs.path.join(a, &.{ home, "tool" });
    chmod(tool, 0o755);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, tool, false)).outcome);

    // A 0644 live file: nothing to record.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const rc = try std.fs.path.join(a, &.{ home, ".zshrc" });
    chmod(rc, 0o644);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, rc, false)).outcome);

    var attrs = try mox.source.attributes.load(a, io, repo);
    try testing.expectEqual(@as(u32, 0o600), attrs.mode(".ssh/config").?);
    try testing.expect(attrs.mode("tool") == null);
    try testing.expect(attrs.mode(".zshrc") == null);
}

test "addFile: --seed-once records seed_once; a plain add does not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    try tmp.dir.createDirPath(io, "home/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app.local", .data = "x\n" });
    const seeded = try std.fs.path.join(a, &.{ home, ".config", "app.local" });
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, seeded, true)).outcome);

    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const plain = try std.fs.path.join(a, &.{ home, ".zshrc" });
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, plain, false)).outcome);

    var attrs = try mox.source.attributes.load(a, io, repo);
    try testing.expect(attrs.seedOnce(".config/app.local"));
    try testing.expect(!attrs.seedOnce(".zshrc"));
}

/// Rebuild and persist the coupling graph over every base source file, keyed by
/// absolute path (matching how `mox commit` and `mox doctor` build it).
fn buildInitialCoupling(ctx: *app.Ctx) !void {
    const context = ctx.context.?;
    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, "") catch return;
    var inputs: std.ArrayList(mox.coupling.index.FileInput) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        // A symlink target / seed-once body is never token-synced, so keep it
        // out of the coupling graph entirely (matches doctor's rescanCoupling).
        if (file.is_symlink or file.create_once) continue;
        const content = Io.Dir.cwd().readFileAlloc(ctx.io, file.source_base_abs, ctx.alloc, .limited(64 * 1024 * 1024)) catch continue;
        try inputs.append(ctx.alloc, .{ .id = file.source_base_abs, .content = content });
    }
    var g = try mox.coupling.index.build(ctx.alloc, inputs.items);
    const coupling_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "coupling" });
    try mox.coupling.store.saveGraph(ctx.alloc, ctx.io, coupling_dir, &g);
}
