//! `mox path` - print the repo directory, for `cd $(mox path)`.
//!
//! The repo lives under a data directory nobody stands in, so reaching it is
//! a real need rather than sugar. stdout carries the bare path and nothing
//! else -- no trailing prose, no `~` contraction -- because its consumer is
//! command substitution, which expands no tilde and forgives no extra word.
//! Anything a human reads about this command goes to stderr.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");

const Spec = struct {};

fn run(ctx: *app.Ctx, _: cli.Args(Spec)) anyerror!u8 {
    try ctx.out.print("{s}\n", .{ctx.context.?.paths.repo_dir});
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "path",
    .summary = "Print the repo directory",
    .usage = "mox path",
    .details = "The sole line on stdout is the path, so 'cd $(mox path)' works.",
    .group = .general,
    .needs_context = true,
}, run);
