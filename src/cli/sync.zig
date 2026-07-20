//! `mox sync` - fetch, merge, and push the dotfiles repo under the mox lock.
//!
//! Git is reached only through the `Git` seam (one `git` invocation rooted in
//! the repo dir), so the decision logic is pure and unit-tested while the
//! end-to-end fetch/merge/push cycle is exercised against a local bare remote.

const std = @import("std");
const EnvironMap = std.process.Environ.Map;
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");

const Io = std.Io;

/// A `git` runner bound to one repo directory. `env` is null in production so
/// git inherits the user's environment (their config, signing, credentials);
/// tests supply a hermetic map to isolate the repo from any ambient config.
pub const Git = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    env: ?*const EnvironMap = null,

    pub const Output = struct {
        code: u8,
        ok: bool,
        stdout: []const u8,
        stderr: []const u8,
    };

    pub fn run(self: Git, argv: []const []const u8) !Output {
        const res = try std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.dir },
            .environ_map = self.env,
        });
        const code: u8 = switch (res.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{
            .code = code,
            .ok = res.term == .exited and code == 0,
            .stdout = res.stdout,
            .stderr = res.stderr,
        };
    }
};

pub const Options = struct {
    pull: bool = true,
    push: bool = true,
};

pub const DirtyKind = enum { clean, dirty };

pub const Status = struct {
    kind: DirtyKind,
    paths: []const []const u8,
};

/// Classify a `git status --porcelain` dump: `dirty` with the changed paths as
/// soon as any entry changed, `clean` when none did. mox writes nothing into
/// the repo of its own accord, so every change is the user's to commit.
pub fn classifyStatus(arena: std.mem.Allocator, porcelain: []const u8) !Status {
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, porcelain, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 4) continue;
        const path = statusPath(line);
        if (path.len == 0) continue;
        try paths.append(arena, path);
    }
    return .{ .kind = if (paths.items.len > 0) .dirty else .clean, .paths = paths.items };
}

/// The working path from one porcelain v1 line. The status code is columns 0-1
/// and column 2 is a space, so the path begins at column 3; a rename/copy is
/// rendered "orig -> new" and the post-change path is the one that matters.
fn statusPath(line: []const u8) []const u8 {
    if (line.len < 4) return "";
    const rest = line[3..];
    if (std.mem.indexOf(u8, rest, " -> ")) |i| return rest[i + 4 ..];
    return rest;
}

/// Fetch/merge/push the repo behind `git`, honoring `opts`. Returns the process
/// exit code (0 success, 1 refusal or failure). It takes no lock and no Context
/// so it is drivable against any repo, e.g. a clone in a test tmp dir.
pub fn syncRepo(git: Git, opts: Options, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const wt = try git.run(&.{ "git", "rev-parse", "--is-inside-work-tree" });
    if (!wt.ok or !std.mem.eql(u8, std.mem.trim(u8, wt.stdout, " \t\r\n"), "true")) {
        try stderr.print("mox sync: {s} is not a git work tree\n", .{git.dir});
        return 1;
    }

    const status = try git.run(&.{ "git", "status", "--porcelain" });
    if (!status.ok) {
        try stderr.print("mox sync: git status failed: {s}", .{status.stderr});
        return 1;
    }
    const cls = try classifyStatus(git.gpa, status.stdout);
    switch (cls.kind) {
        .dirty => {
            try stderr.writeAll("mox sync: uncommitted changes; git commit them before syncing:\n");
            for (cls.paths) |p| try stderr.print("  {s}\n", .{p});
            return 1;
        },
        .clean => {},
    }

    if (opts.pull) {
        const branch_res = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        const branch = std.mem.trim(u8, branch_res.stdout, " \t\r\n");
        const up = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" });
        if (!up.ok) {
            try stderr.print(
                "mox sync: branch '{s}' has no upstream; set one with 'git branch --set-upstream-to'\n",
                .{branch},
            );
            return 1;
        }
        const upstream = std.mem.trim(u8, up.stdout, " \t\r\n");

        const before = try git.run(&.{ "git", "rev-parse", "HEAD" });
        const before_head = std.mem.trim(u8, before.stdout, " \t\r\n");

        const fetch = try git.run(&.{ "git", "fetch" });
        if (!fetch.ok) {
            try stderr.print("mox sync: git fetch failed: {s}", .{fetch.stderr});
            return 1;
        }

        // --ff-only: fast-forward or fail. Never fabricate a merge commit for
        // diverged local history and (with push on) push it unreviewed -- that
        // is the user's call to merge or rebase.
        const merge = try git.run(&.{ "git", "merge", "--ff-only", upstream });
        if (!merge.ok) {
            const conflicts = try git.run(&.{ "git", "diff", "--name-only", "--diff-filter=U" });
            try stderr.writeAll("mox sync: cannot fast-forward (local history diverged or conflicts); merge or rebase manually, then re-run mox sync.\n");
            var cit = std.mem.splitScalar(u8, conflicts.stdout, '\n');
            while (cit.next()) |c| {
                const cp = std.mem.trim(u8, c, " \t\r\n");
                if (cp.len > 0) try stderr.print("  conflict: {s}\n", .{cp});
            }
            return 1;
        }

        const after = try git.run(&.{ "git", "rev-parse", "HEAD" });
        const after_head = std.mem.trim(u8, after.stdout, " \t\r\n");
        if (std.mem.eql(u8, before_head, after_head)) {
            try stdout.writeAll("Already up to date\n");
        } else {
            const range = try std.fmt.allocPrint(git.gpa, "{s}..{s}", .{ before_head, after_head });
            const count = try git.run(&.{ "git", "rev-list", "--count", range });
            try stdout.print("Pulled {s} commit(s)\n", .{std.mem.trim(u8, count.stdout, " \t\r\n")});
        }
    }

    if (opts.push) {
        const push = try git.run(&.{ "git", "push" });
        if (!push.ok) {
            try stderr.print(
                "mox sync: push rejected; run mox sync again to pull first:\n{s}",
                .{push.stderr},
            );
            return 1;
        }
        try stdout.writeAll("Pushed\n");
    }

    return 0;
}

const Spec = struct {
    no_pull: cli.spec.Flag(.{ .help = "skip the pull half" }),
    no_push: cli.spec.Flag(.{ .help = "skip the push half" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const opts = Options{
        .pull = !a.no_pull,
        .push = !a.no_push,
    };

    const lk = (try lock_mod.acquireForCommand(ctx, "sync")) orelse return 1;
    defer lk.release();

    const git = Git{ .gpa = ctx.alloc, .io = ctx.io, .dir = context.paths.repo_dir };
    return syncRepo(git, opts, ctx.out, ctx.err);
}

pub const command = app.command(Spec, .{
    .name = "sync",
    .summary = "Fetch, fast-forward, and push the dotfiles repo",
    .details = "Refuses on uncommitted changes; fast-forwards only, refusing diverged history for the user to merge or rebase.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "classifyStatus: empty tree is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try classifyStatus(arena.allocator(), "");
    try testing.expectEqual(DirtyKind.clean, s.kind);
}

test "classifyStatus: dirty source is listed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try classifyStatus(arena.allocator(), " M src/.zshrc\n");
    try testing.expectEqual(DirtyKind.dirty, s.kind);
    try testing.expectEqual(@as(usize, 1), s.paths.len);
    try testing.expectEqualStrings("src/.zshrc", s.paths[0]);
}

test "classifyStatus: an untracked file is dirty too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try classifyStatus(arena.allocator(), "?? src/.new\nM  src/.zshrc\n");
    try testing.expectEqual(DirtyKind.dirty, s.kind);
    try testing.expectEqual(@as(usize, 2), s.paths.len);
}

test "statusPath: rename yields the post-change path" {
    try testing.expectEqualStrings("src/new", statusPath("R  src/old -> src/new"));
}

// Integration tests: a local bare remote and clones inside the test tmp dir.
// Every push targets that bare repo; nothing ever reaches a network remote.

fn requireGit() !void {
    const res = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "--version" } }) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
    testing.allocator.free(res.stdout);
    testing.allocator.free(res.stderr);
}

fn tmpRoot(arena: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, arena);
    return std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

/// Env that isolates the test repos from ambient git config and, crucially,
/// from mox's own repo: the tmp dir sits inside mox's work tree, so a ceiling
/// at the tmp root stops git discovery from ever climbing into mox's `.git`.
fn hermeticEnv(arena: std.mem.Allocator, root: []const u8) !EnvironMap {
    var m = EnvironMap.init(arena);
    const path = testing.environ.getAlloc(arena, "PATH") catch "";
    try m.put("PATH", path);
    try m.put("HOME", root);
    try m.put("GIT_CEILING_DIRECTORIES", root);
    try m.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try m.put("GIT_CONFIG_SYSTEM", "/dev/null");
    try m.put("GIT_TERMINAL_PROMPT", "0");
    try m.put("GIT_AUTHOR_NAME", "mox test");
    try m.put("GIT_AUTHOR_EMAIL", "mox-test@example.invalid");
    try m.put("GIT_COMMITTER_NAME", "mox test");
    try m.put("GIT_COMMITTER_EMAIL", "mox-test@example.invalid");
    return m;
}

fn okRun(git: Git, argv: []const []const u8) !void {
    const r = try git.run(argv);
    if (!r.ok) {
        std.debug.print("git failed (code {d}): {s}\nstdout: {s}\nstderr: {s}\n", .{ r.code, argv[1], r.stdout, r.stderr });
        return error.GitCommandFailed;
    }
}

const Fixture = struct {
    arena: std.mem.Allocator,
    io: Io,
    env: *const EnvironMap,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    remote: []const u8,
    a: []const u8,
    b: []const u8,

    fn seam(self: Fixture, dir: []const u8) Git {
        return .{ .gpa = self.arena, .io = self.io, .dir = dir, .env = self.env };
    }

    fn logSubject(self: Fixture, dir: []const u8) ![]const u8 {
        const r = try self.seam(dir).run(&.{ "git", "log", "-1", "--format=%s" });
        return std.mem.trim(u8, r.stdout, " \t\r\n");
    }
};

/// Build `<root>/remote.git` (bare) with clones `a` (producer) and `b`
/// (consumer), both tracking `origin/main` with an initial `src/.zshrc`.
fn setupFixture(arena: std.mem.Allocator, env: *const EnvironMap, tmp: *std.testing.TmpDir, root: []const u8) !Fixture {
    const io = testing.io;
    const remote = try std.fs.path.join(arena, &.{ root, "remote.git" });
    const a = try std.fs.path.join(arena, &.{ root, "a" });
    const b = try std.fs.path.join(arena, &.{ root, "b" });
    const root_git = Git{ .gpa = arena, .io = io, .dir = root, .env = env };

    try okRun(root_git, &.{ "git", "init", "--bare", "-b", "main", remote });
    try okRun(root_git, &.{ "git", "clone", remote, a });

    try tmp.dir.createDirPath(io, "a/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/src/.zshrc", .data = "line\n" });

    const a_git = Git{ .gpa = arena, .io = io, .dir = a, .env = env };
    try okRun(a_git, &.{ "git", "add", "--", "src/.zshrc" });
    try okRun(a_git, &.{ "git", "commit", "-m", "init" });
    try okRun(a_git, &.{ "git", "push", "-u", "origin", "main" });

    try okRun(root_git, &.{ "git", "clone", remote, b });

    return .{ .arena = arena, .io = io, .env = env, .tmp = tmp, .root = root, .remote = remote, .a = a, .b = b };
}

test "sync: not a git repo is refused" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    try tmp.dir.createDirPath(testing.io, "plain");
    const plain = try std.fs.path.join(al, &.{ root, "plain" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const git = Git{ .gpa = al, .io = testing.io, .dir = plain, .env = &env };
    const rc = try syncRepo(git, .{}, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 1), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "not a git work tree") != null);
}

test "sync: clean tree with pull and push off is a no-op" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    const before = try fx.logSubject(fx.b);
    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.b), .{ .pull = false, .push = false }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
}

test "sync: fast-forwards N commits from the remote" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    // Producer advances the remote by one commit.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "line\nsecond\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "second" });
    try okRun(fx.seam(fx.a), &.{ "git", "push" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.b), .{ .pull = true, .push = false }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pulled 1") != null);

    const pulled = try tmp.dir.readFileAlloc(testing.io, "b/src/.zshrc", al, .limited(4096));
    try testing.expectEqualStrings("line\nsecond\n", pulled);
}

test "sync: an untracked file is refused, never auto-committed" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/untracked.toml", .data = "x = 1\n" });
    const before = try fx.logSubject(fx.b);

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.b), .{ .pull = false, .push = true }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 1), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "untracked.toml") != null);

    // Nothing was committed on mox's own initiative: HEAD is unmoved, and the
    // file is still the user's to commit.
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
    const status = try fx.seam(fx.b).run(&.{ "git", "status", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, status.stdout, "untracked.toml") != null);
}

test "sync: dirty source is refused and nothing is committed" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/src/.zshrc", .data = "hand edit\n" });
    const before = try fx.logSubject(fx.b);

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.b), .{ .pull = true, .push = true }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 1), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "src/.zshrc") != null);
    // HEAD unmoved: nothing was committed and the edit remains uncommitted.
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
    const status = try fx.seam(fx.b).run(&.{ "git", "status", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, status.stdout, "src/.zshrc") != null);
}

test "sync: divergent history is refused, not auto-merged" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    // Producer changes the shared line and publishes it.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "AAA\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "producer edit" });
    try okRun(fx.seam(fx.a), &.{ "git", "push" });

    // Consumer commits a conflicting change to the same line (clean tree, but
    // diverged from the remote).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/src/.zshrc", .data = "BBB\n" });
    try okRun(fx.seam(fx.b), &.{ "git", "commit", "-am", "consumer edit" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.b), .{ .pull = true, .push = false }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 1), rc);
    // --ff-only refuses to fabricate a merge commit for diverged history; it
    // tells the user to merge or rebase rather than auto-merging (and pushing).
    try testing.expect(std.mem.indexOf(u8, err.written(), "cannot fast-forward") != null);

    // No merge was started: no unmerged entries and the consumer's own commit
    // is intact -- nothing was auto-merged or reset underneath the user.
    const unmerged = try fx.seam(fx.b).run(&.{ "git", "diff", "--name-only", "--diff-filter=U" });
    try testing.expect(std.mem.trim(u8, unmerged.stdout, " \t\r\n").len == 0);
    const head = try fx.seam(fx.b).run(&.{ "git", "log", "-1", "--pretty=%s" });
    try testing.expect(std.mem.indexOf(u8, head.stdout, "consumer edit") != null);
}

test "sync: no upstream configured is refused" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();

    try tmp.dir.createDirPath(testing.io, "solo");
    const solo = try std.fs.path.join(al, &.{ root, "solo" });
    const git = Git{ .gpa = al, .io = testing.io, .dir = solo, .env = &env };
    try okRun(git, &.{ "git", "init", "-b", "main" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "solo/f", .data = "x\n" });
    try okRun(git, &.{ "git", "add", "--", "f" });
    try okRun(git, &.{ "git", "commit", "-m", "init" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(git, .{ .pull = true, .push = false }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 1), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "upstream") != null);
    try testing.expect(std.mem.indexOf(u8, err.written(), "main") != null);
}

test "sync: no-pull pushes local commits to the bare remote" {
    try requireGit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(al, &tmp);
    var env = try hermeticEnv(al, root);
    defer env.deinit();
    const fx = try setupFixture(al, &env, &tmp, root);

    // A local commit that is not yet on the remote.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "line\npush-only\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "local only" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try syncRepo(fx.seam(fx.a), .{ .pull = false, .push = true }, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pushed") != null);
    try testing.expectEqualStrings("local only", try fx.logSubject(fx.remote));
}
