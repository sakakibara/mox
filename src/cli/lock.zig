//! Single-writer lock for mutating commands.
//!
//! A mutating command -- add, apply, commit, mv, publish, remove, rollback,
//! uninstall, update, private retire, facts set, facts ask, a bare facts that
//! reaches the interview, and doctor under a rebuild flag -- takes the kernel
//! lock on `mox.lock` in the state directory before touching anything. The
//! lock is per state directory, so it serializes runs that share one and
//! nothing else. The system releases it when its holder exits, however it
//! exits, so no lock is ever left behind to clear by hand.

const std = @import("std");
const app = @import("app.zig");
const mox = @import("../root.zig");
const state_lock = mox.state.lock;

pub const Lock = state_lock.Lock;

pub const Taken = union(enum) {
    lock: Lock,
    /// The lock was not taken, and why was said: the command exits with
    /// this code.
    exit: u8,
};

/// Take the lock for `command`, printing why to stderr when it cannot be
/// taken: the command then exits `busy`, or 2 for a state directory that is
/// not mox's. On success the caller owns the returned Lock and must
/// `release()` it (typically via `defer`).
pub fn acquireForCommand(ctx: *app.Ctx, command: []const u8, busy: u8) !Taken {
    switch (try state_lock.acquire(ctx.alloc, ctx.io, ctx.context.?.paths.state_dir, ctx.context.?.paths.state_origin, command)) {
        .acquired => |l| return .{ .lock = l },
        .held => |h| {
            try printHeld(ctx, h);
            return .{ .exit = busy };
        },
        .unsupported => |errno| {
            try printUnsupported(ctx, errno);
            return .{ .exit = busy };
        },
        .refused => |why| {
            try ctx.err.writeAll(why);
            return .{ .exit = 2 };
        },
    }
}

/// The refusal for a lock another process holds, which only waiting frees.
pub fn printHeld(ctx: *app.Ctx, h: state_lock.Held) !void {
    if (h.pid == 0) {
        try ctx.err.writeAll("lock held by another mox that has not yet said who it is; wait\n");
    } else {
        try ctx.err.print("lock held by {d} ({s}); wait\n", .{ h.pid, h.command });
    }
}

pub fn printUnsupported(ctx: *app.Ctx, errno: []const u8) !void {
    try ctx.err.print("mox: the state directory {s} cannot be locked ({s}); mox does not run without its lock\n", .{ ctx.context.?.paths.state_dir, errno });
}
