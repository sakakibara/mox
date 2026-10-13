//! How a command opens the state: recovery, and every line it says, printed
//! the same way for every command.

const std = @import("std");
const app = @import("app.zig");
const mox = @import("../root.zig");
const state = mox.state;

pub const Open = struct {
    run_kind: state.generation.Kind = .apply,
    undoes: ?[]const u8 = null,
    /// The run writes state; false for a reader and for a dry run.
    writes: bool,
    /// The caller holds the lock.
    locked: bool,
    repair: bool = false,
};

/// The state for this command, or null after saying why it cannot run.
pub fn open(ctx: *app.Ctx, o: Open) !?*state.Draft {
    const r = (try openWithReport(ctx, o)) orelse return null;
    return r.draft;
}

pub const Opened = struct { draft: *state.Draft, report: state.recovery.Report };

/// `open`, with what loading the state found.
pub fn openWithReport(ctx: *app.Ctx, o: Open) !?Opened {
    const context = ctx.context.?;
    const opened = try state.open(ctx.alloc, ctx.io, .{
        .state_dir = context.paths.state_dir,
        .repo_dir = context.paths.repo_dir,
        .home = context.paths.home,
        .run_kind = o.run_kind,
        .undoes = o.undoes,
        .writes = o.writes,
        .locked = o.locked,
        .repair = o.repair,
    });
    switch (opened) {
        .refused => |why| {
            try ctx.err.writeAll(why);
            return null;
        },
        .ready => |r| {
            for (r.report.warnings.items) |w| try ctx.err.print("mox: warning: {s}\n", .{w});
            for (r.report.quarantined.items) |q| try ctx.err.print("mox: warning: a journal that could not be recovered was moved to {s}\n", .{q});
            if (o.writes and r.draft.exhausted) {
                try ctx.err.print("mox: the state at {s} has no readable generation; run `mox doctor --fix`\n", .{context.paths.state_dir});
                return null;
            }
            return .{ .draft = r.draft, .report = r.report };
        },
    }
}

/// Commit what `st` holds: false, after saying so, when `current` moved
/// underneath it and nothing was committed.
pub fn commit(ctx: *app.Ctx, st: *state.Draft, opts: state.recovery.CommitOptions) !bool {
    _ = state.recovery.commit(st, opts) catch |e| switch (e) {
        error.StateChanged => {
            try ctx.err.print("mox: the state changed while this run held its lock; what it recorded was moved to {s} and is not current\n", .{st.store.quarantine});
            return false;
        },
        else => return e,
    };
    return true;
}

/// Commit what `st` holds once the command's body has given `rc`, its exit
/// code, or failed: a commit refused because `current` moved exits 2.
pub fn finish(ctx: *app.Ctx, st: *state.Draft, opts: state.recovery.CommitOptions, rc: anyerror!u8) anyerror!u8 {
    const code = rc catch |e| {
        _ = commit(ctx, st, opts) catch false;
        return e;
    };
    if (!try commit(ctx, st, opts)) return 2;
    return code;
}
