//! What mox persists about what it applied: one history of generations under
//! `<state>/v2/`, each committed atomically. This module is the only code
//! that opens anything there.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const generation = @import("generation.zig");
pub const blob = @import("blob.zig");
pub const journal = @import("journal.zig");
pub const draft = @import("draft.zig");
pub const recovery = @import("recovery.zig");
pub const retention = @import("retention.zig");
pub const id = @import("id.zig");
pub const lock = @import("lock.zig");
pub const durable = @import("durable.zig");
pub const dump = @import("dump.zig");
const quote = @import("quote.zig");

pub const Draft = draft.Draft;
pub const Store = draft.Store;
pub const Hex = generation.Hex;

pub const Options = struct {
    state_dir: []const u8,
    repo_dir: []const u8,
    home: []const u8,
    run_kind: generation.Kind = .apply,
    undoes: ?[]const u8 = null,
    /// The run writes state. False for a reader and for a dry run.
    writes: bool,
    /// The caller holds the lock.
    locked: bool,
    /// Writes go ahead on an exhausted chain: `doctor --fix` starts over.
    repair: bool = false,
    /// What a step that waits for the readers says first.
    wait: ?lock.Wait = null,
};

pub const Opened = union(enum) {
    ready: Ready,
    /// The command must not run; the message says why.
    refused: []const u8,
    /// The readers lock cannot be taken: the errno, by name.
    unsupported: []const u8,
};

pub const Ready = struct {
    draft: *Draft,
    report: recovery.Report,
};

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn nonEmptyDir(arena: std.mem.Allocator, io: Io, path: []const u8) bool {
    const entries = @import("../source/dirent.zig").sortedPath(arena, io, path, .{ .iterate = true }) catch return false;
    return entries.len > 0;
}

/// Load the state for a command: recovery, then the draft.
pub fn open(arena: std.mem.Allocator, io: Io, opts: Options) !Opened {
    const store = try Store.init(arena, opts.state_dir);

    // A reader takes the readers lock as it looks for the store: one found
    // missing then reads as empty, whatever is created after.
    const no_store = if (opts.writes) false else switch (try holdReaders(arena, io, store)) {
        .ok => false,
        .no_store => true,
        .stop => |why| return why,
    };
    if (builtin.is_test) if (before_reader_load) |f| f(io);
    var report: recovery.Report = .{};
    var loaded: recovery.Loaded = if (no_store) .{ .gen = null, .base = "" } else try recovery.loadCurrent(arena, io, store, &report);
    if (report.newer) |v| return .{ .refused = try std.fmt.allocPrint(arena, "mox: state written by a newer mox (v{d}); upgrade mox to use {s}\n", .{ v, opts.state_dir }) };
    if (!exists(io, store.current)) {
        if (!no_store and exists(io, store.v2) and nonEmptyDir(arena, io, store.gen)) {
            var probe: recovery.Report = .{};
            const adopted = try recovery.recover(arena, io, store, loaded, .{ .writes = false, .unlocked = !opts.locked }, &probe);
            if (adopted.gen == null) {
                report.exhausted = true;
                try report.warnings.append(arena, try std.fmt.allocPrint(arena, "{s} holds generations but no current one; the state reads as empty, and every command that writes refuses until `mox doctor --fix`", .{store.v2}));
            }
        }
    }
    if (report.exhausted and opts.repair and opts.writes and opts.locked) {
        // Starting over: what cannot be read moves aside, and the state is
        // empty, `current` absent.
        const excl = try lock.waitExclusive(io, store.readers, store.v2, opts.wait);
        defer if (excl) |x| x.release();
        try quarantineUnreadable(arena, io, store, &report);
        if (exists(io, store.current)) try recovery.quarantine(arena, io, store, store.current, &report);
        loaded = .{ .gen = null, .base = "" };
        report.restarted = true;
    }
    if (!no_store and (!report.exhausted or opts.repair)) {
        loaded = try recovery.recover(arena, io, store, loaded, .{ .writes = opts.writes and opts.locked, .unlocked = !opts.locked }, &report);
    }
    const part = try draft.partOf(arena, io, opts.repo_dir, opts.home);
    const d = try arena.create(Draft);
    var gen: generation.Generation = if (loaded.gen) |g| try g.clone(arena) else .{ .id = "", .kind = opts.run_kind, .run_kind = opts.run_kind };
    gen.displaced = .empty;
    d.* = .{
        .arena = arena,
        .io = io,
        .store = store,
        .writable = opts.writes,
        .gen = gen,
        .base = loaded.base,
        .loaded = if (loaded.gen) |g| g.id else null,
        .run_kind = opts.run_kind,
        .undoes = opts.undoes,
        .part = part.hex,
        .part_info = part.info,
        .exhausted = report.exhausted and !opts.repair,
        .unwritten = report.unwritten.items,
        .wait = opts.wait,
    };
    return .{ .ready = .{ .draft = d, .report = report } };
}

/// The displaced history under a state directory: the store.
pub const History = struct {
    path: []const u8,
    present: bool,
};

pub fn history(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !History {
    const path = try std.fs.path.join(arena, &.{ state_dir, draft.store_dir_name });
    return .{ .path = path, .present = exists(io, path) };
}

/// True when `name`, a top-level entry of a state directory, holds the
/// displaced history.
pub fn isHistory(name: []const u8) bool {
    return std.mem.eql(u8, name, draft.store_dir_name);
}

pub const Deleted = struct { path: []const u8, err: ?anyerror = null };

/// Claim an id for a run that trashes without a journal, as a journal's id
/// is claimed.
pub fn claimTrashId(arena: std.mem.Allocator, io: Io, state_dir: []const u8) ![]const u8 {
    return draft.claimId(arena, io, try Store.init(arena, state_dir), .trash);
}

/// Delete the history, `v2/`, whatever state it is in: no generation needs
/// to be readable. Waits for the readers first.
pub fn purgeHistory(arena: std.mem.Allocator, io: Io, state_dir: []const u8, wait: ?lock.Wait) !?Deleted {
    const store = try Store.init(arena, state_dir);
    const excl = try lock.waitExclusive(io, store.readers, store.v2, wait);
    defer if (excl) |x| x.release();
    const h = try history(arena, io, state_dir);
    if (!h.present) return null;
    Io.Dir.cwd().deleteTree(io, h.path) catch |e| return .{ .path = h.path, .err = e };
    return .{ .path = h.path };
}

/// Move every generation file that does not parse into `quarantine/`.
pub fn quarantineUnreadable(arena: std.mem.Allocator, io: Io, store: Store, report: *recovery.Report) !void {
    const inv = try retention.inventory(arena, io, store);
    for (inv.unreadable) |gid| try recovery.quarantine(arena, io, store, try store.genPath(arena, gid), report);
}

/// The readers lock this process holds for the command it runs.
var held_readers: ?lock.Readers = null;

/// Hold the readers lock until `releaseReaders`, so no generation or blob the
/// command reads is deleted under it: `no_store` when there is no store. A
/// lock file that is missing and cannot be created is read without; any
/// other failure is why the command cannot run.
fn holdReaders(arena: std.mem.Allocator, io: Io, store: Store) !union(enum) { ok, no_store, stop: Opened } {
    if (held_readers != null) return .ok;
    switch (lock.holdReaders(io, store.readers, store.v2)) {
        .held => |r| held_readers = r,
        .no_store => return .no_store,
        .unavailable => {},
        .failed => |e| return .{ .stop = try readersFailure(arena, store.readers, e) },
    }
    return .ok;
}

fn readersFailure(arena: std.mem.Allocator, path: []const u8, e: anyerror) !Opened {
    return switch (e) {
        error.FileLocksUnsupported => .{ .unsupported = "ENOTSUP" },
        error.SystemResources => .{ .unsupported = "ENOLCK" },
        error.AccessDenied, error.PermissionDenied => .{ .refused = if (builtin.os.tag == .windows)
            try std.fmt.allocPrint(arena, "mox: cannot open {s}, which a command reading the state holds ({s}); make it readable by you\n", .{ path, @errorName(e) })
        else
            try std.fmt.allocPrint(arena, "mox: cannot open {s}, which a command reading the state holds ({s}); make it readable by you: chmod 600 {s}\n", .{ path, @errorName(e), try quote.sh(arena, path) }) },
        else => .{ .refused = try std.fmt.allocPrint(arena, "mox: cannot lock {s}, which a command reading the state holds ({s}); it must be a file you own, on a local filesystem\n", .{ path, @errorName(e) }) },
    };
}

/// Why a step that waits for the readers could not take their lock, as a
/// reader is told; null when none failed.
pub fn exclusiveFailure(arena: std.mem.Allocator) !?Opened {
    const f = lock.exclusive_failure orelse return null;
    return try readersFailure(arena, f.path, f.err);
}

/// Release the readers lock a command's reads took, at the command's end.
pub fn releaseReaders() void {
    if (held_readers) |r| r.release();
    held_readers = null;
}

/// The test seam between a reader's attempt at the readers lock and its
/// load.
pub var before_reader_load: ?*const fn (Io) void = null;

pub const Expectation = union(enum) {
    expects: bool,
    /// The command must not run; the message says why.
    refused: []const u8,
    /// The readers lock cannot be taken: the errno, by name.
    unsupported: []const u8,
};

/// Whether this repo and HOME expect a private layer, read without the lock,
/// a dead run's journal included.
pub fn expectsPrivate(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo_dir: []const u8, home: []const u8) !Expectation {
    const store = try Store.init(arena, state_dir);
    const attempt = lock.holdReaders(io, store.readers, store.v2);
    if (builtin.is_test) if (before_reader_load) |f| f(io);
    const readers: ?lock.Readers = switch (attempt) {
        .held => |r| r,
        .no_store => return .{ .expects = false },
        .unavailable => null,
        .failed => |e| return switch (try readersFailure(arena, store.readers, e)) {
            .refused => |why| .{ .refused = why },
            .unsupported => |errno| .{ .unsupported = errno },
            else => unreachable,
        },
    };
    defer if (readers) |r| r.release();
    var report: recovery.Report = .{};
    const loaded = try recovery.loadCurrent(arena, io, store, &report);
    if (report.newer != null or report.exhausted) return .{ .expects = false };
    const at = try recovery.recover(arena, io, store, loaded, .{ .writes = false, .unlocked = true }, &report);
    const g = at.gen orelse return .{ .expects = false };
    const part = try draft.partOf(arena, io, repo_dir, home);
    const f = g.flags.get(&part.hex) orelse return .{ .expects = false };
    return .{ .expects = f.expects_private };
}

test {
    _ = generation;
    _ = blob;
    _ = journal;
    _ = draft;
    _ = recovery;
    _ = quote;
    _ = retention;
    _ = id;
    _ = lock;
    _ = durable;
    _ = dump;
}
