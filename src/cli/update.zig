//! `mox update` - fetch, rebase, and apply, under the mox lock.
//!
//! The inbound edge: remote -> source -> live. The name promises a machine
//! brought current, so applying is the default and `--no-apply` is the way to
//! stop and look first -- an unwanted apply is snapshotted and reversible, and
//! apply already refuses to overwrite drifted files. The outbound edge is not
//! the mirror of that, because a push cannot be recalled; it is `mox publish`,
//! a verb you type on purpose.
//!
//! Rebase rather than fast-forward-only: the same repo edited on several
//! machines diverges as a matter of course, and `--ff-only` would hand back a
//! manual rebase every time. No `--autostash` -- a dirty tree is refused
//! before the fetch, so there is nothing to stash.
//!
//! Git is reached only through the `Git` seam (one `git` invocation rooted in
//! the repo dir), so the decision logic is pure and unit-tested while the
//! end-to-end fetch/rebase cycle is exercised against a local bare remote.

const std = @import("std");
const EnvironMap = std.process.Environ.Map;
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const apply_cmd = @import("apply.zig");
const style = @import("style.zig");
const mox = @import("../root.zig");

const Io = std.Io;

/// A `git` runner bound to one repo directory.
///
/// `env` is the environment mox itself reads through, not the raw process one.
/// In production those are the same value, so git still sees the user's config,
/// signing, and credentials. They differ exactly when a caller hands mox a
/// synthetic environment -- the test harness does -- and git seeing a different
/// one than mox was given is the inconsistency this closes: a run told to use
/// one HOME would otherwise resolve mox's paths from it while git read the
/// operator's real `~/.gitconfig`, picking up their commit signing and
/// credential helpers.
///
/// Null falls back to the process environment, for a caller with no Env to
/// hand over (the unit tests below construct the seam directly).
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

/// Fetch and rebase the repo behind `git`. Returns 0 on success and 2 on any
/// refusal or failure -- never 1, which `mox update` reserves for apply's
/// "drift left for a decision". It takes no lock and no Context so it is
/// drivable against any repo, e.g. a clone in a test tmp dir.
pub fn fetchRebase(git: Git, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const wt = try git.run(&.{ "git", "rev-parse", "--is-inside-work-tree" });
    if (!wt.ok or !std.mem.eql(u8, std.mem.trim(u8, wt.stdout, " \t\r\n"), "true")) {
        try stderr.print("mox update: {s} is not a git work tree\n", .{git.dir});
        return 2;
    }

    const status = try git.run(&.{ "git", "status", "--porcelain" });
    if (!status.ok) {
        try stderr.print("mox update: git status failed: {s}", .{status.stderr});
        return 2;
    }
    const cls = try classifyStatus(git.gpa, status.stdout);
    switch (cls.kind) {
        .dirty => {
            try stderr.writeAll("mox update: uncommitted changes; commit them before updating:\n");
            for (cls.paths) |p| try stderr.print("  {s}\n", .{p});
            return 2;
        },
        .clean => {},
    }

    const branch_res = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
    const branch = std.mem.trim(u8, branch_res.stdout, " \t\r\n");
    const up = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" });
    if (!up.ok) {
        try stderr.print(
            "mox update: branch '{s}' has no upstream; set one with 'git branch --set-upstream-to'\n",
            .{branch},
        );
        return 2;
    }
    const upstream = std.mem.trim(u8, up.stdout, " \t\r\n");

    const fetch = try git.run(&.{ "git", "fetch" });
    if (!fetch.ok) {
        try stderr.print("mox update: git fetch failed: {s}", .{fetch.stderr});
        return 2;
    }

    // Counted against the fetched upstream BEFORE the rebase: this is how many
    // commits arrived, which a HEAD-before/HEAD-after range cannot express
    // once local commits are replayed on top of them.
    const range = try std.fmt.allocPrint(git.gpa, "HEAD..{s}", .{upstream});
    const count_res = try git.run(&.{ "git", "rev-list", "--count", range });
    const incoming = std.mem.trim(u8, count_res.stdout, " \t\r\n");

    // Rebase, not --ff-only: the same repo edited on several machines diverges
    // routinely, and refusing that hands back a manual rebase every time. Only
    // commits absent from the upstream are replayed, so published history is
    // never rewritten. A conflict stops mid-rebase, which apply and commit
    // both refuse until it is resolved or aborted.
    const rebase = try git.run(&.{ "git", "rebase", upstream });
    if (!rebase.ok) {
        const conflicts = try git.run(&.{ "git", "diff", "--name-only", "--diff-filter=U" });
        try stderr.writeAll("mox update: rebase stopped on a conflict; resolve it and 'git rebase --continue', or 'git rebase --abort', then re-run mox update.\n");
        var cit = std.mem.splitScalar(u8, conflicts.stdout, '\n');
        while (cit.next()) |c| {
            const cp = std.mem.trim(u8, c, " \t\r\n");
            if (cp.len > 0) try stderr.print("  conflict: {s}\n", .{cp});
        }
        return 2;
    }

    if (std.mem.eql(u8, incoming, "0")) {
        try stdout.writeAll("Already up to date\n");
    } else {
        try stdout.print("Pulled {s} commit(s)\n", .{incoming});
    }

    return 0;
}

const Spec = struct {
    no_apply: cli.Flag(.{ .help = "stop after the fetch; write no live files" }),
    color: cli.Opt(style.ColorFlag, .{ .default = "auto", .value_name = "color", .help = "auto|always|never" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;

    // The git phase holds the lock; apply takes its own, so the scope ends
    // before it runs rather than deadlocking against the same process.
    {
        const lk = (try lock_mod.acquireForCommand(ctx, "update")) orelse return 2;
        defer lk.release();

        var env_map = try context.env.createMap(ctx.alloc);
        const git = Git{ .gpa = ctx.alloc, .io = ctx.io, .dir = context.paths.repo_dir, .env = &env_map };
        const rc = try fetchRebase(git, ctx.out, ctx.err);
        if (rc != 0) return rc;
    }

    if (a.no_apply) return 0;
    return apply_cmd.applyImpl(ctx, false, false, false, false, a.color orelse .auto, &.{});
}

pub const command = app.command(Spec, .{
    .name = "update",
    .summary = "Fetch, rebase, and apply",
    .details = "Brings this machine up to date: fetches, rebases onto the upstream, then applies. Refuses on uncommitted changes; a rebase conflict stops for you to resolve or abort. --no-apply stops after the fetch so you can 'mox diff' first. Exit 0 clean, 1 drift left for a decision, 2 a refusal or failure. Sending work the other way is 'mox publish'.",
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

test "update: not a git repo is refused" {
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
    const rc = try fetchRebase(git, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 2), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "not a git work tree") != null);
}

test "update: a clean tree level with the remote reports up to date and moves nothing" {
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
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Already up to date") != null);
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
}

test "update: replays onto N commits arriving from the remote" {
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
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pulled 1") != null);

    const pulled = try tmp.dir.readFileAlloc(testing.io, "b/src/.zshrc", al, .limited(4096));
    try testing.expectEqualStrings("line\nsecond\n", pulled);
}

test "update: an untracked file is refused, never auto-committed" {
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
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 2), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "untracked.toml") != null);

    // Nothing was committed on mox's own initiative: HEAD is unmoved, and the
    // file is still the user's to commit.
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
    const status = try fx.seam(fx.b).run(&.{ "git", "status", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, status.stdout, "untracked.toml") != null);
}

test "update: dirty source is refused and nothing is committed" {
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
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 2), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "src/.zshrc") != null);
    // HEAD unmoved: nothing was committed and the edit remains uncommitted.
    try testing.expectEqualStrings(before, try fx.logSubject(fx.b));
    const status = try fx.seam(fx.b).run(&.{ "git", "status", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, status.stdout, "src/.zshrc") != null);
}

test "update: divergent history rebases, keeping both sides" {
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

    // Producer publishes a change to one file.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "line\nproducer\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "producer edit" });
    try okRun(fx.seam(fx.a), &.{ "git", "push" });

    // Consumer commits a change to a DIFFERENT file: diverged, not conflicting
    // -- the ordinary multi-machine state.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/src/.vimrc", .data = "consumer\n" });
    try okRun(fx.seam(fx.b), &.{ "git", "add", "--", "src/.vimrc" });
    try okRun(fx.seam(fx.b), &.{ "git", "commit", "-m", "consumer edit" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);
    // One commit arrived, counted against the upstream rather than against a
    // HEAD that the replay moved.
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pulled 1") != null);

    // Both sides survive: the consumer's commit is replayed on top of the
    // producer's, and the producer's file content is present.
    const head = try fx.seam(fx.b).run(&.{ "git", "log", "-1", "--pretty=%s" });
    try testing.expect(std.mem.indexOf(u8, head.stdout, "consumer edit") != null);
    const pulled = try tmp.dir.readFileAlloc(testing.io, "b/src/.zshrc", al, .limited(4096));
    try testing.expectEqualStrings("line\nproducer\n", pulled);
}

test "update: a conflicting rebase stops and says how to resolve it" {
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

    // Both sides change the same line.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "AAA\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "producer edit" });
    try okRun(fx.seam(fx.a), &.{ "git", "push" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/src/.zshrc", .data = "BBB\n" });
    try okRun(fx.seam(fx.b), &.{ "git", "commit", "-am", "consumer edit" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try fetchRebase(fx.seam(fx.b), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 2), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "rebase stopped on a conflict") != null);
    try testing.expect(std.mem.indexOf(u8, err.written(), "git rebase --abort") != null);

    // Left mid-rebase on purpose: the repo now carries the marker apply and
    // commit refuse on, rather than being silently reset underneath the user.
    try testing.expectEqualStrings("rebase", (try mox.source.vcs.inProgress(al, testing.io, fx.b)).?);
}

test "update: no upstream configured is refused" {
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
    const rc = try fetchRebase(git, &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 2), rc);
    try testing.expect(std.mem.indexOf(u8, err.written(), "upstream") != null);
    try testing.expect(std.mem.indexOf(u8, err.written(), "main") != null);
}

test "update: local commits are never published, only the user pushes" {
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

    const remote_before = try fx.logSubject(fx.remote);

    // A local commit that is not yet on the remote.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/src/.zshrc", .data = "line\nlocal\n" });
    try okRun(fx.seam(fx.a), &.{ "git", "commit", "-am", "local only" });

    var out: Io.Writer.Allocating = .init(al);
    var err: Io.Writer.Allocating = .init(al);
    const rc = try fetchRebase(fx.seam(fx.a), &out.writer, &err.writer);
    try testing.expectEqual(@as(u8, 0), rc);

    // The remote is untouched: sync fetches and fast-forwards, and publishing
    // stays the user's own `git push`.
    try testing.expectEqualStrings(remote_before, try fx.logSubject(fx.remote));
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pushed") == null);

    // The local commit is intact -- nothing was reset underneath the user.
    try testing.expectEqualStrings("local only", try fx.logSubject(fx.a));
}
