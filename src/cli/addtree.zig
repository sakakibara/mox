//! `mox add-tree <dir>`: recursively start managing every non-junk regular
//! file and symlink under a live directory, reusing the single-file add path.
//! Already-managed files, junk (editor temp, OS metadata), and non-regular
//! entries (FIFO, socket, device) are counted as skipped. Under the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const edit = @import("edit.zig");
const add = @import("add.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const Counts = struct {
    added: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

const Spec = struct {
    dir: cli.Pos([]const u8, .{ .help = "live directory to start managing" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const dir_abs = try edit.liveTarget(ctx.alloc, a.dir, context.paths.home);

    const lk = (try lock_mod.acquireForCommand(ctx, "add-tree")) orelse return 1;
    defer lk.release();

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
            try ctx.err.print("mox add-tree: {s}: not found\n", .{dir_abs});
            return 1;
        },
        error.NotDir => {
            try ctx.err.print("mox add-tree: {s}: not a directory (use 'mox add' for a single file)\n", .{dir_abs});
            return 1;
        },
        else => return e,
    };
    if (st.kind != .directory) {
        try ctx.err.print("mox add-tree: {s}: not a directory (use 'mox add' for a single file)\n", .{dir_abs});
        return 1;
    }

    // A tree outside HOME is refused at the top level, exactly as single add
    // refuses the file: every child would fail the same membership check, and
    // "Added 0 file(s)" over a real directory would read as success. HOME
    // itself stays walkable (its children are all under HOME).
    if (try mox.source.path.liveKeyUnderHome(ctx.alloc, context.paths.home, dir_abs)) |rel| {
        if (mox.source.path.keyEscapes(rel)) {
            try ctx.err.print("mox add-tree: {s}: outside HOME ({s})\n", .{ dir_abs, context.paths.home });
            return 1;
        }
    } else if (!add.isHomeItself(dir_abs, context.paths.home)) {
        try ctx.err.print("mox add-tree: {s}: outside HOME ({s})\n", .{ dir_abs, context.paths.home });
        return 1;
    }

    var counts: Counts = .{};
    try walk(ctx, dir_abs, &ruleset, &counts);

    // Rebuild the coupling graph once over the whole bulk add, so the new
    // files' tokens can couple with existing sources on the next commit
    // (single-file add rebuilds for the same reason).
    if (counts.added > 0) add.buildInitialCoupling(ctx, "add-tree");

    try ctx.out.print("Added {d} file(s); {d} skipped, {d} failed\n", .{ counts.added, counts.skipped, counts.failed });
    return if (counts.failed > 0) 1 else 0;
}

fn walk(ctx: *app.Ctx, dir_abs: []const u8, ruleset: *const mox.source.ignore.match.RuleSet, counts: *Counts) !void {
    const context = ctx.context.?;
    // Sorted so a tree is added, reported, and recursed in the same order on
    // every machine; entries are captured before the walk mutates the repo.
    const entries = try mox.source.dirent.sortedPath(ctx.alloc, ctx.io, dir_abs, .{ .iterate = true, .follow_symlinks = false });

    const home = context.env.getAlloc(ctx.alloc, "HOME") catch context.paths.home;

    for (entries) |entry| {
        const child = try std.fs.path.join(ctx.alloc, &.{ dir_abs, entry.name });
        switch (entry.kind) {
            .directory => {
                const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, child);
                if (ruleset.isIgnored(rel, true)) {
                    counts.skipped += 1;
                    continue;
                }
                try walk(ctx, child, ruleset, counts);
            },
            // A symlink is captured like single add captures it: as a regular
            // source file holding the target string, flagged in attributes.
            .file, .sym_link => {
                const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, child);
                if (mox.source.junk.isJunk(entry.name) or ruleset.isIgnored(rel, false)) {
                    counts.skipped += 1;
                    continue;
                }
                // Bulk-adding a tree never seeds once; only single-file add
                // exposes the intent.
                const result = add.addFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, child, false, null) catch {
                    counts.failed += 1;
                    continue;
                };
                switch (result.outcome) {
                    .added => {
                        counts.added += 1;
                        try ctx.out.print("  added {s}\n", .{child});
                        if (mox.source.ignore.load.looksLikeSecret(std.fs.path.basename(child))) {
                            try ctx.out.print("  note: {s} looks like a secret and will be committed\n", .{child});
                        }
                    },
                    .already_managed => counts.skipped += 1,
                    // A partially owned target is managed per key-path; a
                    // whole-file capture would sweep the program's region in.
                    .partial_target => {
                        counts.skipped += 1;
                        try ctx.out.print("  skipping {s} (partially owned; managed per key-path)\n", .{child});
                    },
                    .not_regular => {
                        counts.skipped += 1;
                        try ctx.out.print("  skipping {s} (not a regular file)\n", .{child});
                    },
                    else => counts.skipped += 1,
                }
            },
            // A FIFO/socket/device is not capturable content and must never be
            // opened (a FIFO read blocks): count it, with the reason, instead
            // of pretending it was not there.
            else => {
                counts.skipped += 1;
                try ctx.out.print("  skipping {s} (not a regular file)\n", .{child});
            },
        }
    }
}

pub const command = app.command(Spec, .{
    .name = "add-tree",
    .summary = "Recursively add every non-junk file under a live dir",
    .usage = "mox add-tree <dir>",
    .group = .general,
    .needs_context = true,
}, run);
