//! `mox publish` - the outbound edge: live -> source -> remote.
//!
//! Outbound never defaults on. `update` applies without being asked because a
//! wrong apply is snapshotted and one command undoes it; a push cannot be
//! recalled, so publishing is a verb you type rather than a flag you forget to
//! suppress. That is also why this is not `update --push`: it is the other
//! direction, and it sits at the same altitude as the command it mirrors.
//!
//! It does not route live edits. Moving a live-file edit into its source is
//! `mox commit`, which prompts per hunk about axes and shared tokens; folding
//! that in would put those questions in the middle of an outbound run and make
//! one verb mean two kinds of work.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const update_cmd = @import("update.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const Git = update_cmd.Git;

/// Commit the source tree (when `message` is given) and push. Returns 0 on
/// success and 2 on any refusal or failure, matching the rest of the surface.
/// Takes no lock and no Context so it is drivable against a test clone.
pub fn publishRepo(git: Git, message: ?[]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const wt = try git.run(&.{ "git", "rev-parse", "--is-inside-work-tree" });
    if (!wt.ok or !std.mem.eql(u8, std.mem.trim(u8, wt.stdout, " \t\r\n"), "true")) {
        try stderr.print("mox publish: {s} is not a git work tree\n", .{git.dir});
        return 2;
    }

    const status = try git.run(&.{ "git", "status", "--porcelain" });
    if (!status.ok) {
        try stderr.print("mox publish: git status failed: {s}", .{status.stderr});
        return 2;
    }
    const cls = try update_cmd.classifyStatus(git.gpa, status.stdout);

    if (message) |msg| {
        // Staged by explicit path, never `-A` or a wildcard: a dotfiles repo
        // is exactly where a stray note, an editor temp file, or a pasted
        // credential ends up, and a blanket stage would publish it. Only the
        // directories mox itself owns are publish's to commit; anything else
        // dirty is reported and left for the user to stage deliberately.
        var ours: std.ArrayList([]const u8) = .empty;
        var theirs: std.ArrayList([]const u8) = .empty;
        for (cls.paths) |p| {
            if (isSourceTreePath(p)) try ours.append(git.gpa, p) else try theirs.append(git.gpa, p);
        }

        if (ours.items.len == 0) {
            try stdout.writeAll("Nothing to commit\n");
        } else {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(git.gpa, &.{ "git", "add", "--" });
            try argv.appendSlice(git.gpa, ours.items);
            const add = try git.run(argv.items);
            if (!add.ok) {
                try stderr.print("mox publish: git add failed: {s}", .{add.stderr});
                return 2;
            }
            const commit = try git.run(&.{ "git", "commit", "-m", msg });
            if (!commit.ok) {
                try stderr.print("mox publish: git commit failed: {s}", .{commit.stderr});
                return 2;
            }
            for (ours.items) |p| try stdout.print("  committed {s}\n", .{p});
        }

        for (theirs.items) |p| {
            try stderr.print("  not committed: {s} (outside mox's tree; stage it yourself with 'mox git -- add')\n", .{p});
        }
    } else if (cls.kind == .dirty) {
        // No message and something to commit: refuse rather than invent one or
        // silently publish a subset of the user's work.
        try stderr.writeAll("mox publish: uncommitted changes; pass -m <message> to commit them, or commit them yourself:\n");
        for (cls.paths) |p| try stderr.print("  {s}\n", .{p});
        return 2;
    }

    const branch_res = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
    const branch = std.mem.trim(u8, branch_res.stdout, " \t\r\n");
    const up = try git.run(&.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" });
    if (!up.ok) {
        try stderr.print(
            "mox publish: branch '{s}' has no upstream; set one with 'git branch --set-upstream-to'\n",
            .{branch},
        );
        return 2;
    }
    const upstream = std.mem.trim(u8, up.stdout, " \t\r\n");

    // Counted before the push, so the report names what this run sent rather
    // than reporting success for a push that carried nothing.
    const range = try std.fmt.allocPrint(git.gpa, "{s}..HEAD", .{upstream});
    const count_res = try git.run(&.{ "git", "rev-list", "--count", range });
    const outgoing = std.mem.trim(u8, count_res.stdout, " \t\r\n");
    if (std.mem.eql(u8, outgoing, "0")) {
        try stdout.writeAll("Nothing to publish\n");
        return 0;
    }

    const push = try git.run(&.{ "git", "push" });
    if (!push.ok) {
        try stderr.print("mox publish: push rejected; run 'mox update' first:\n{s}", .{push.stderr});
        return 2;
    }
    try stdout.print("Published {s} commit(s) to {s}\n", .{ outgoing, upstream });
    return 0;
}

/// The repo directories mox itself owns, and so the only ones `publish -m`
/// stages. Everything else in the repo -- a README, a note, whatever a user
/// keeps beside their sources -- is theirs to stage deliberately.
const source_tree_roots = [_][]const u8{ "src/", "data/", "scripts/", ".mox/" };
const source_tree_files = [_][]const u8{ ".moxignore", ".mox/attributes.toml" };

fn isSourceTreePath(path: []const u8) bool {
    for (source_tree_roots) |root| {
        if (std.mem.startsWith(u8, path, root)) return true;
    }
    for (source_tree_files) |f| {
        if (std.mem.eql(u8, path, f)) return true;
    }
    return false;
}

const Spec = struct {
    message: cli.Opt([]const u8, .{ .short = 'm', .value_name = "message", .help = "commit the source tree with this message before pushing" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;

    const lk = (try lock_mod.acquireForCommand(ctx, "publish")) orelse return 2;
    defer lk.release();

    // A half-resolved tree must not be committed and sent out, the same
    // refusal apply and commit make.
    if (try mox.source.vcs.inProgress(ctx.alloc, ctx.io, context.paths.repo_dir)) |operation| {
        try ctx.err.print(
            "mox publish: {s} is part-way through a {s}; finish or abort it first\n",
            .{ context.paths.repo_dir, operation },
        );
        return 2;
    }

    var env_map = try context.env.createMap(ctx.alloc);
    const git = Git{ .gpa = ctx.alloc, .io = ctx.io, .dir = context.paths.repo_dir, .env = &env_map };
    return publishRepo(git, a.message, ctx.out, ctx.err);
}

pub const command = app.command(Spec, .{
    .name = "publish",
    .summary = "Commit the source tree and push",
    .usage = "mox publish [-m <message>]",
    .details = "The outbound edge: sends this machine's work to the remote. With -m it commits the repo's pending source changes first; without it, it pushes what is already committed and refuses a dirty tree rather than inventing a message. Never routes live-file edits -- that is 'mox commit'. Bringing work the other way is 'mox update'.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "isSourceTreePath: mox's own directories, and nothing else in the repo" {
    try testing.expect(isSourceTreePath("src/.zshrc"));
    try testing.expect(isSourceTreePath("data/completions.toml"));
    try testing.expect(isSourceTreePath("scripts/post/theme.sh"));
    try testing.expect(isSourceTreePath(".mox/attributes.toml"));
    try testing.expect(isSourceTreePath(".moxignore"));

    // The cases a blanket stage would have swept into a published commit.
    try testing.expect(!isSourceTreePath("README.md"));
    try testing.expect(!isSourceTreePath("notes.txt"));
    try testing.expect(!isSourceTreePath(".env"));
    try testing.expect(!isSourceTreePath("id_rsa"));
    // A path merely starting with the same bytes is not inside the directory.
    try testing.expect(!isSourceTreePath("srcnotes.md"));
}
