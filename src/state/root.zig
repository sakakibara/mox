//! What mox persists about what it applied: one history of generations under
//! `<state>/v2/`, each committed atomically. This module is the only code
//! that opens anything there.

const std = @import("std");
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
};

pub const Opened = union(enum) {
    ready: Ready,
    /// The command must not run; the message says why.
    refused: []const u8,
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
    var report: recovery.Report = .{};
    var loaded = try recovery.loadCurrent(arena, io, store, &report);
    if (report.newer) |v| return .{ .refused = try std.fmt.allocPrint(arena, "mox: state written by a newer mox (v{d}); upgrade mox to use {s}\n", .{ v, opts.state_dir }) };
    if (!exists(io, store.current)) {
        if (exists(io, store.v2) and nonEmptyDir(arena, io, store.gen)) {
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
        try quarantineUnreadable(arena, io, store, &report);
        if (exists(io, store.current)) try recovery.quarantine(arena, io, store, store.current, &report);
        loaded = .{ .gen = null, .base = "" };
        report.restarted = true;
    }
    if (!report.exhausted or opts.repair) {
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
    };
    return .{ .ready = .{ .draft = d, .report = report } };
}

/// Move every generation file that does not parse into `quarantine/`.
pub fn quarantineUnreadable(arena: std.mem.Allocator, io: Io, store: Store, report: *recovery.Report) !void {
    const inv = try retention.inventory(arena, io, store);
    for (inv.unreadable) |gid| try recovery.quarantine(arena, io, store, try store.genPath(arena, gid), report);
}

/// Whether this repo and HOME expect a private layer, read without the lock,
/// a dead run's journal included.
pub fn expectsPrivate(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo_dir: []const u8, home: []const u8) !bool {
    const store = try Store.init(arena, state_dir);
    var report: recovery.Report = .{};
    const loaded = try recovery.loadCurrent(arena, io, store, &report);
    if (report.newer != null or report.exhausted) return false;
    const at = try recovery.recover(arena, io, store, loaded, .{ .writes = false, .unlocked = true }, &report);
    const g = at.gen orelse return false;
    const part = try draft.partOf(arena, io, repo_dir, home);
    const f = g.flags.get(&part.hex) orelse return false;
    return f.expects_private;
}

test {
    _ = generation;
    _ = blob;
    _ = journal;
    _ = draft;
    _ = recovery;
    _ = retention;
    _ = id;
    _ = lock;
    _ = durable;
    _ = dump;
}
