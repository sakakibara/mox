//! `mox git -- <args>` - run git in the repo, from anywhere.
//!
//! One passthrough rather than a bespoke mox verb per git verb: `log`,
//! `rebase`, `stash`, and everything else stay git's vocabulary, spelled the
//! way git spells them, and mox grows no surface as git does. The two edges
//! mox does name (`update`, `publish`) earn their commands by doing more than
//! git -- guarded, applied, reported -- not by wrapping a verb.
//!
//! git's own stdout, stderr, and exit code pass through untouched. mox adds no
//! interpretation: a caller piping `mox git -- log --format=%H` gets exactly
//! what git wrote.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");

const Io = std.Io;

const Spec = struct {
    args: cli.Rest(.{ .help = "git arguments; put flags after --" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;

    if (a.args.len == 0) {
        try ctx.err.writeAll("mox git: usage: mox git -- <args>\n");
        return 2;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.alloc, "git");
    try argv.appendSlice(ctx.alloc, a.args);

    // Inherited stdio: git's pager, colors, and prompts behave as they do in
    // a shell rooted at the repo, which is the whole point of the passthrough.
    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = context.paths.repo_dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.writeAll("mox git: git is not on PATH\n");
            return 2;
        },
        else => return e,
    };
    return switch (try child.wait(ctx.io)) {
        .exited => |code| code,
        else => 2,
    };
}

pub const command = app.command(Spec, .{
    .name = "git",
    .summary = "Run git in the repo",
    .usage = "mox git -- <args>",
    .details = "Runs git in the repo dir from wherever you are, passing its output and exit code through untouched. Put flags after -- so mox does not read them: 'mox git -- log --oneline'.",
    .group = .general,
    .needs_context = true,
}, run);
