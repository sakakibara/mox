//! The recursive half of `mox add`: every non-junk regular file and symlink
//! under a live directory, captured through the same single-file path.
//! Already-managed files, junk (editor temp, OS metadata), and non-regular
//! entries (FIFO, socket, device) are counted as skipped.
//!
//! Not a command of its own. `mox add -r <dir>` owns the argument, the lock,
//! and the home check; this is the walk it runs, kept apart so the
//! single-file body stays readable.

const std = @import("std");
const app = @import("app.zig");
const add = @import("add.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");

const Io = std.Io;

const Counts = struct {
    added: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

/// Capture every eligible file under `dir_abs`. The caller has already
/// resolved the path, taken the lock, and confirmed a home is named.
/// `seed_once` and `force` carry the flags `mox add` accepts in both modes.
pub fn runRecursive(
    ctx: *app.Ctx,
    dir_abs: []const u8,
    seed_once: bool,
    force: bool,
) anyerror!u8 {
    const context = ctx.context.?;

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    var bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings_map);
    var bindings: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };
    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);

    // sortedPath maps a missing directory to an empty listing (a contract its
    // optional-dir callers rely on), so a mistyped top-level dir must be
    // probed here or the walk would report success over nothing. A file
    // argument is refused for the same reason: opening it as a directory
    // would surface a raw NotDir instead of pointing at 'mox add'.
    const st = Io.Dir.cwd().statFile(ctx.io, dir_abs, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox add: {f}: not found\n", .{display.of(dir_abs, context.paths.home)});
            return 1;
        },
        error.NotDir => {
            try ctx.err.print("mox add: {f}: not a directory (drop --recursive for a single file)\n", .{display.of(dir_abs, context.paths.home)});
            return 1;
        },
        else => return e,
    };
    if (st.kind != .directory) {
        try ctx.err.print("mox add: {f}: not a directory (drop --recursive for a single file)\n", .{display.of(dir_abs, context.paths.home)});
        return 1;
    }

    // A tree outside HOME is refused at the top level, exactly as single add
    // refuses the file: every child would fail the same membership check, and
    // "Added 0 file(s)" over a real directory would read as success. HOME
    // itself stays walkable (its children are all under HOME).
    if (try mox.source.path.liveKeyUnderHome(ctx.alloc, context.paths.home, dir_abs)) |rel| {
        if (mox.source.path.keyEscapes(rel)) {
            try ctx.err.print("mox add: {f}: outside HOME ({s})\n", .{ display.of(dir_abs, context.paths.home), context.paths.home });
            return 1;
        }
    } else if (!add.isHomeItself(dir_abs, context.paths.home)) {
        try ctx.err.print("mox add: {f}: outside HOME ({s})\n", .{ display.of(dir_abs, context.paths.home), context.paths.home });
        return 1;
    }

    var counts: Counts = .{};
    try walk(ctx, dir_abs, &ruleset, &counts, seed_once, force);

    // Rebuild the coupling graph once over the whole bulk add, so the new
    // files' tokens can couple with existing sources on the next commit
    // (single-file add rebuilds for the same reason).
    if (counts.added > 0) add.buildInitialCoupling(ctx, "add");

    try ctx.out.print("Added {d} file(s); {d} skipped, {d} failed\n", .{ counts.added, counts.skipped, counts.failed });
    return if (counts.failed > 0) 1 else 0;
}

fn walk(
    ctx: *app.Ctx,
    dir_abs: []const u8,
    ruleset: *const mox.source.ignore.match.RuleSet,
    counts: *Counts,
    seed_once: bool,
    force: bool,
) !void {
    const context = ctx.context.?;
    // Sorted so a tree is added, reported, and recursed in the same order on
    // every machine; entries are captured before the walk mutates the repo.
    const entries = try mox.source.dirent.sortedPath(ctx.alloc, ctx.io, dir_abs, .{ .iterate = true, .follow_symlinks = false });

    const home = context.paths.home;

    for (entries) |entry| {
        const child = try std.fs.path.join(ctx.alloc, &.{ dir_abs, entry.name });
        switch (entry.kind) {
            .directory => {
                const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, child);
                if (!force and ruleset.isIgnored(rel, true)) {
                    counts.skipped += 1;
                    continue;
                }
                try walk(ctx, child, ruleset, counts, seed_once, force);
            },
            // A symlink is captured like single add captures it: as a regular
            // source file holding the target string, flagged in attributes.
            .file, .sym_link => {
                const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, child);
                // Junk is never captured, `--force` or not: an editor swap
                // file is noise in every repo, where an ignore rule is the
                // user's own policy and theirs to override.
                if (mox.source.junk.isJunk(entry.name) or (!force and ruleset.isIgnored(rel, false))) {
                    counts.skipped += 1;
                    continue;
                }
                const result = add.addFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, child, seed_once, null) catch {
                    counts.failed += 1;
                    continue;
                };
                switch (result.outcome) {
                    .added => {
                        counts.added += 1;
                        try ctx.out.print("  added {f}\n", .{display.of(child, home)});
                        if (mox.source.ignore.load.looksLikeSecret(std.fs.path.basename(child))) {
                            try ctx.out.print("  note: {f} looks like a secret and will be committed\n", .{display.of(child, home)});
                        }
                    },
                    .already_managed => counts.skipped += 1,
                    // A partially owned target is managed per key-path; a
                    // whole-file capture would sweep the program's region in.
                    .partial_target => {
                        counts.skipped += 1;
                        try ctx.out.print("  skipping {f} (partially owned; managed per key-path)\n", .{display.of(child, home)});
                    },
                    .not_regular => {
                        counts.skipped += 1;
                        try ctx.out.print("  skipping {f} (not a regular file)\n", .{display.of(child, home)});
                    },
                    else => counts.skipped += 1,
                }
            },
            // A FIFO/socket/device is not capturable content and must never be
            // opened (a FIFO read blocks): count it, with the reason, instead
            // of pretending it was not there.
            else => {
                counts.skipped += 1;
                try ctx.out.print("  skipping {f} (not a regular file)\n", .{display.of(child, home)});
            },
        }
    }
}
