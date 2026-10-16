const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const apply_cmd = @import("apply.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");
const state_cli = @import("state.zig");
const State = mox.state.Draft;

const Io = std.Io;

/// `mox rollback [<id>]`: restore every live file a generation displaced,
/// defaulting to the newest one.
///
/// Last-applied records of restored files are deliberately left stale, so
/// the next `mox apply` sees them as drift and refuses to overwrite them
/// without --overwrite. Rollback undoes live-file changes; it never touches
/// the source tree. What it replaces is kept in a generation of its own.
///
/// A PARTIALLY owned target is never whole-file restored: that would clobber
/// the program's remainder as it stood at snapshot time. Its snapshot is
/// re-patched onto the CURRENT live file through the full partial pipeline
/// (splice, invariant, `check` hook, raced-write recheck). A snapshot whose
/// owned values were secret-masked is refused -- placeholders are never
/// written live; re-apply the source instead.
const Spec = struct {
    id: cli.Pos([]const u8, .{ .optional = true, .help = "snapshot id (see 'mox snapshot'); the newest when omitted" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const lk = switch (try lock_mod.acquireForCommand(ctx, "rollback", 1)) {
        .lock => |l| l,
        .exit => |rc| return rc,
    };
    defer lk.release();
    const st = (try state_cli.open(ctx, .{ .run_kind = .rollback, .writes = true, .locked = true })) orelse return 2;
    return state_cli.finish(ctx, st, .{}, rollbackOpened(ctx, a, st));
}

fn rollbackOpened(ctx: *app.Ctx, a: cli.Args(Spec), st: *mox.state.Draft) anyerror!u8 {
    const context = ctx.context.?;

    // Undoing the apply just run is the case that matters, and making the user
    // read an id back out of `mox snapshot` to reach it is pure friction. The
    // chosen id is announced, so an unattended run still records what it took.
    const id = a.id orelse blk: {
        // What a rollback kept of what it replaced is rolled back only when
        // named.
        var ids: std.ArrayList([]const u8) = .empty;
        for (try st.listed()) |l| {
            if (l.gen.kind == .rollback or l.gen.run_kind == .rollback) continue;
            try ids.append(ctx.alloc, l.id);
        }
        if (ids.items.len == 0) {
            try ctx.err.writeAll("mox rollback: no snapshots to roll back to\n");
            return 1;
        }
        const newest = ids.items[ids.items.len - 1];
        try ctx.err.print("mox rollback: rolling back the newest snapshot, {s}\n", .{newest});
        break :blk newest;
    };

    // Resolved once per rollback run (not per re-patched partial file): an
    // unparseable override would otherwise warn once per file re-patched.
    var check_env_map = try context.env.createMap(ctx.alloc);
    const check_timeout_ms = mox.apply.run_scripts.checkTimeoutMs(&check_env_map, ctx.err);

    // Tree info for the re-patch (own paths, check hook, format), best
    // effort: a broken source tree must not block the
    // whole-file restores, so a failed walk leaves the map empty and only
    // the withheld partial targets report an error below.
    var partials: std.StringHashMap(mox.source.tree.ManagedFile) = .init(ctx.alloc);
    {
        const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
        var walk_diag: mox.source.tree.Diag = .{};
        // An attributes file that cannot be read or parsed leaves the
        // whole-file restores to run: recovery must stay possible.
        var unusable: ?[]const u8 = null;
        for ([_][2][]const u8{ .{ context.paths.repo_dir, ".mox/attributes.toml" }, .{ context.paths.private_dir, "private .mox/attributes.toml" } }) |f| {
            if (unusable == null) unusable = try mox.source.attributes.unusable(ctx.alloc, ctx.io, f[0], f[1]);
        }
        if (unusable) |why| try ctx.err.print("mox rollback: warning: {s}; whole-file restores proceed, partial targets cannot be re-patched\n", .{why});
        const base_tree: ?mox.source.tree.ManagedTree = if (unusable != null) null else mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, context.paths.home, &walk_diag) catch |e| switch (e) {
            error.FileNotFound => null,
            error.OwnOnSymlink,
            error.OwnOnSeedOnce,
            error.OwnOnGenerator,
            error.OwnAndDisown,
            error.OwnPathOverlap,
            error.InvalidOwnPath,
            error.InvalidCheckDirective,
            error.CheckWithoutOwnership,
            => blk: {
                try ctx.err.print("mox rollback: warning: ownership declaration: {s}: {s}; whole-file restores proceed, partial targets cannot be re-patched\n", .{
                    walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
                });
                break :blk null;
            },
            error.TomlParseError,
            => blk: {
                try ctx.err.print("mox rollback: warning: {s}; whole-file restores proceed, partial targets cannot be re-patched\n", .{try mox.source.attributes.parseFailure(ctx.alloc, ctx.io, context.paths.repo_dir)});
                break :blk null;
            },
            else => return e,
        };
        if (base_tree) |bt| {
            const merged = mox.private.layer.merge(ctx.alloc, ctx.io, bt, context.paths.private_dir, context.paths.home) catch |e| switch (e) {
                error.TomlParseError => blk: {
                    try ctx.err.print("mox rollback: warning: {s}; whole-file restores proceed, partial targets cannot be re-patched\n", .{try mox.source.attributes.parseFailureNamed(ctx.alloc, ctx.io, context.paths.private_dir, "private .mox/attributes.toml")});
                    break :blk null;
                },
                else => return e,
            };
            if (merged) |tree| for (tree.files) |f| {
                if (f.own_paths.len == 0) continue;
                try partials.put(f.live_path, f);
            };
        }
    }

    const src = (try st.displacedOf(id)) orelse {
        try ctx.err.print("mox rollback: no snapshot '{s}' (see 'mox snapshot')\n", .{id});
        return 1;
    };
    st.undoes = id;

    // Partial targets are detected by OWNED RECORD existence, not by the
    // walked tree: the records were written by the same runs that displaced
    // the content, and unlike the tree they stay readable when the repo is
    // broken -- a whole-file restore over a partial target must never
    // happen just because the walk failed.
    var skip: std.StringHashMap(void) = .init(ctx.alloc);
    for (src.displaced.keys(), src.displaced.values()) |key, d| {
        if (d.type != .file) continue;
        const lp = try mox.source.path.joinKeyOnto(ctx.alloc, context.paths.home, key);
        if ((try st.readOwned(lp)) != null) try skip.put(lp, {});
    }

    var withheld: std.ArrayList(mox.apply.snapshot.Withheld) = .empty;
    const restored = mox.apply.snapshot.restoreExcept(ctx.alloc, ctx.io, st, src, context.paths.home, &skip, &withheld) catch |e| {
        // Whatever was kept before the failure stays recoverable: say where.
        if (st.hasDisplaced()) try ctx.out.print("  what it replaced is kept in snapshot {s} ('mox rollback {s}' puts it back)\n", .{ st.run_id.?, st.run_id.? });
        return e;
    };

    var repatched: usize = 0;
    var failed: usize = 0;
    for (restored.filled) |live| try ctx.out.print("  {f}: secret slots filled from the file it replaced\n", .{display.of(live, context.paths.home)});
    for (restored.refused) |r| {
        const shown = display.of(r.live_path, context.paths.home);
        switch (r.why) {
            .parent_link => try ctx.err.print("  ERROR   {f} (not restored: a parent directory is a symlink; {f})\n", .{ shown, r.copy }),
            .is_link => try ctx.err.print("  ERROR   {f} (not restored: it is a symlink mox did not plant; {f})\n", .{ shown, r.copy }),
            .owned_masked => try ctx.err.print("  ERROR   {f} (not restored: its copy is masked at the owned secret paths of a file mox no longer manages in part; {f}, fill its {s} markers by hand)\n", .{ shown, r.copy, mox.provenance.map.secret_redaction }),
            .lines_not_kept => try ctx.err.print("  ERROR   {f} (not restored: the copy leaves out {d} line(s) that may have held a secret; {f}, restore it by hand)\n", .{ shown, r.count, r.copy }),
            .fill_gone => try ctx.err.print("  ERROR   {f} (not restored: the copy leaves out a secret, and no file is there to fill it from; {f}, fill its {s} markers by hand)\n", .{ shown, r.copy, mox.provenance.map.secret_redaction }),
            .fill_link => try ctx.err.print("  ERROR   {f} (not restored: the copy leaves out a secret, and a symlink is there to fill it from; {f}, fill its {s} markers by hand)\n", .{ shown, r.copy, mox.provenance.map.secret_redaction }),
            .fill_stale => try ctx.err.print("  ERROR   {f} (not restored: the copy leaves out a secret, and the file it would replace is not the one mox last wrote, so it cannot fill it from; {f}, fill its {s} markers by hand)\n", .{ shown, r.copy, mox.provenance.map.secret_redaction }),
            .fill_changed => try ctx.err.print("  ERROR   {f} (not restored: the copy leaves out a secret, and the file it would replace does not hold the same secret lines to fill it from; {f}, fill its {s} markers by hand)\n", .{ shown, r.copy, mox.provenance.map.secret_redaction }),
            .failed => try ctx.err.print("  ERROR   {f} (not restored: {s}; {f})\n", .{ shown, r.reason, r.copy }),
            .dir_over_link => try ctx.err.print("  ERROR   {f} (not restored: a symlink sits where the snapshot has a directory; {f})\n", .{ shown, r.copy }),
            .missing => try ctx.err.print("  ERROR   {f} (not restored: the snapshot copy at {s} is missing or damaged)\n", .{ shown, r.copy.blob }),
            .not_kept => try ctx.err.print("  ERROR   {f} (not restored: no line of it was kept, since each may have held a secret mox wrote)\n", .{shown}),
        }
        failed += 1;
    }
    // Resolved on the first check hook, once for the run: a run that spawns
    // none leaves the state directory as it is.
    var mox_bin_dir: ?[]const u8 = null;
    var mox_bin_resolved = false;
    // A partial target is re-patched from what composes now, which without
    // an expected private layer would drop its private part: while the
    // layer is unavailable only whole files are restored.
    const private_down = st.expectsPrivate() and !try mox.private.layer.holdsSource(ctx.alloc, ctx.io, context.paths.private_dir);
    if (private_down) try ctx.err.print("mox rollback: warning: private layer {f} is unavailable but held sources before; whole files are restored, partially owned files are not re-patched\n", .{display.of(context.paths.private_dir, context.paths.home)});
    for (withheld.items) |w| {
        if (private_down) {
            try ctx.err.print("  ERROR   {f} (not re-patched: the private layer is unavailable)\n", .{display.of(w.live_path, context.paths.home)});
            failed += 1;
            continue;
        }
        const file = partials.get(w.live_path) orelse {
            try ctx.err.print("  ERROR   {f} (partially owned, but its own declaration is unavailable; fix the source tree, then re-run)\n", .{display.of(w.live_path, ctx.context.?.paths.home)});
            failed += 1;
            continue;
        };
        if (file.check_argv.len > 0 and !mox_bin_resolved) {
            mox_bin_resolved = true;
            var mox_bin_why: ?[]const u8 = null;
            mox_bin_dir = try mox.apply.run_scripts.moxBinDir(ctx.alloc, ctx.io, ctx.context.?.paths.state_dir, &mox_bin_why);
            if (mox_bin_why) |why| try ctx.err.print("mox rollback: warning: the running mox is not on the check hooks' PATH: {s}\n", .{why});
        }
        if (try repatchPartial(ctx, st, file, w.content, check_timeout_ms, &failed, mox_bin_dir)) repatched += 1;
    }

    try ctx.out.print("Restored {d} file(s) from snapshot {s}\n", .{ restored.count + repatched, id });
    if (st.hasDisplaced()) try ctx.out.print("  what it replaced is kept in snapshot {s} ('mox rollback {s}' puts it back)\n", .{ st.run_id.?, st.run_id.? });
    return if (failed > 0) 1 else 0;
}

/// Re-patch one partial target's owned subtree from its snapshot onto the
/// CURRENT live file. The owned record is deliberately left stale; the next
/// apply reconciles through the drift rule, mirroring whole-file rollback.
/// Returns true on success; a refusal reports, bumps `failed`, and leaves
/// the live file untouched.
fn repatchPartial(
    ctx: *app.Ctx,
    st: *State,
    file: mox.source.tree.ManagedFile,
    snap_content: []const u8,
    check_timeout_ms: i64,
    failed: *usize,
    mox_bin_dir: ?[]const u8,
) !bool {
    const partial = mox.apply.partial;
    const live_path = file.live_path;
    const format = file.format.?;
    var pdiag: partial.Diag = .{};

    const snap_doc = partial.OwnedDoc.parse(ctx.alloc, format, snap_content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {f} (snapshot does not parse as {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), @tagName(format) });
            failed.* += 1;
            return false;
        },
    };
    const masked = switch (file.ownership) {
        .disown => try partial.complementHasSecretMask(ctx.alloc, &snap_doc, file.own_paths),
        else => partial.ownedHasSecretMask(&snap_doc, file.own_paths),
    };
    if (masked) {
        try ctx.err.print("  ERROR   {f} (snapshot masks a secret; placeholders are never written live -- re-apply the source instead)\n", .{display.of(live_path, ctx.context.?.paths.home)});
        failed.* += 1;
        return false;
    }

    // A symlinked live path is re-patched at its resolved target, same as
    // apply's partial path; a dangling link is refused, live untouched.
    const live_target = mox.apply.write.resolvePartialLive(ctx.alloc, ctx.io, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => {
            try ctx.err.print("  ERROR   {f} (live path is a dangling symlink; fix or remove the link)\n", .{display.of(live_path, ctx.context.?.paths.home)});
            failed.* += 1;
            return false;
        },
    };
    // Stat before the read so a write landing between the two refuses at
    // the post-fsync recheck, same as apply's partial path.
    const pre_stat = mox.apply.write.liveStat(ctx.io, live_target);
    const live: ?[]const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, live_target, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            try ctx.err.print("mox rollback: {f}: read failed: {s}\n", .{ display.of(live_path, ctx.context.?.paths.home), @errorName(e) });
            failed.* += 1;
            return false;
        },
    };
    const live_stat: ?mox.apply.write.LiveStat = if (live != null) pre_stat else null;
    const live_text = live orelse "";
    _ = partial.OwnedDoc.parse(ctx.alloc, format, live_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            const shown = try std.fmt.allocPrint(ctx.alloc, "{f}", .{display.of(live_path, ctx.context.?.paths.home)});
            try ctx.err.print("  ERROR   {s} ({s}; the live file does not parse, and mox cannot patch what it cannot preserve)\n", .{ shown, try partial.liveParseError(ctx.alloc, format, live_text, try std.fmt.allocPrint(ctx.alloc, "live {s}", .{shown})) });
            failed.* += 1;
            return false;
        },
    };

    // Disown mode re-patches the snapshot's owned COMPLEMENT: the snapshot
    // text minus its disowned spans plays the composed text's role, and the
    // current live file's disowned spans are preserved.
    var snap_owned_text: []const u8 = "";
    if (file.ownership == .disown) {
        const snap_loc = partial.locateSpans(ctx.alloc, format, snap_content, file.own_paths, &pdiag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try ctx.err.print("  ERROR   {f} (snapshot: {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), pdiag.text() });
                failed.* += 1;
                return false;
            },
        };
        snap_owned_text = try partial.textWithoutSpans(ctx.alloc, format, snap_content, snap_loc);
    }
    const snap_owned_doc = if (file.ownership == .disown)
        partial.OwnedDoc.parse(ctx.alloc, format, snap_owned_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OwnedUnparseable => {
                try ctx.err.print("  ERROR   {f} (snapshot owned content does not parse as {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), @tagName(format) });
                failed.* += 1;
                return false;
            },
        }
    else
        snap_doc;

    const candidate = (switch (file.ownership) {
        .disown => partial.replaceDisowned(ctx.alloc, format, live_text, file.own_paths, snap_owned_text, &pdiag),
        else => partial.replaceOwned(ctx.alloc, format, live_text, file.own_paths, &snap_doc, &pdiag),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {f} ({s})\n", .{ display.of(live_path, ctx.context.?.paths.home), pdiag.text() });
            failed.* += 1;
            return false;
        },
    };
    apply_cmd.invariantVerdict(switch (file.ownership) {
        .disown => partial.verifyDisownInvariant(ctx.alloc, format, live_text, candidate, file.own_paths, snap_owned_text, &snap_owned_doc, &pdiag),
        else => partial.verifyInvariant(ctx.alloc, format, live_text, candidate, file.own_paths, &snap_doc, &pdiag),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {f} (invariant check failed: {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), pdiag.text() });
            failed.* += 1;
            return false;
        },
    };
    // A rollback must not install content the file's own validator rejects.
    if (file.check_argv.len > 0) {
        if (!try apply_cmd.partialCheckAccepts(ctx, file.check_argv, live_path, candidate, check_timeout_ms, failed, &.{}, mox_bin_dir)) return false;
    }

    // A live target absent here is legitimate (this partial target was never
    // materialized); any other stat failure is a real anomaly and must not
    // silently degrade the mode a rollback writes back.
    const mode = blk: {
        const stat = Io.Dir.cwd().statFile(ctx.io, live_target, .{}) catch |e| switch (e) {
            error.FileNotFound => break :blk @as(u32, 0o644),
            else => return e,
        };
        break :blk mox.apply.write.modeOf(stat.permissions);
    };
    // What the re-patch replaces is kept, as a whole-file restore keeps it,
    // its secret-bearing owned values masked as apply's snapshot masks them.
    if (live) |held| if (!std.mem.eql(u8, held, candidate)) keep: {
        const rec = try st.readOwned(live_path);
        const secret_paths: []const mox.source.tree.OwnPath = if (rec) |r| try mox.apply.owned.parseRawPaths(ctx.alloc, r.secret_paths) else &.{};
        const kept = partial.maskSecretPaths(ctx.alloc, format, held, secret_paths) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MaskFailed => {
                try ctx.err.print("  ERROR   {f} (not re-patched: what it holds could not be kept with its secrets masked)\n", .{display.of(live_path, ctx.context.?.paths.home)});
                failed.* += 1;
                return false;
            },
        };
        mox.apply.snapshot.keepBytes(st, ctx.context.?.paths.home, live_target, kept, !std.mem.eql(u8, kept, held)) catch |e| switch (e) {
            // A partial target linked outside HOME has no place in a snapshot.
            error.LiveFileOutsideHome => break :keep,
            else => {
                try ctx.err.print("  ERROR   {f} (not re-patched: what it holds could not be kept first: {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), @errorName(e) });
                failed.* += 1;
                return false;
            },
        };
    };
    mox.apply.write.writeAtomicPartial(ctx.io, live_target, candidate, mode, live_stat) catch |e| switch (e) {
        error.LiveChangedDuringWrite => {
            try ctx.err.print("  CONFLICT {f} (changed underneath mox mid-rollback; re-run 'mox rollback')\n", .{display.of(live_path, ctx.context.?.paths.home)});
            failed.* += 1;
            return false;
        },
        else => {
            try ctx.err.print("mox rollback: {f}: write failed: {s}\n", .{ display.of(live_path, ctx.context.?.paths.home), @errorName(e) });
            failed.* += 1;
            return false;
        },
    };
    try ctx.out.print("  re-patched {f} (owned subtree from the snapshot; remainder kept current)\n", .{display.of(live_path, ctx.context.?.paths.home)});
    return true;
}

pub const command = app.command(Spec, .{
    .name = "rollback",
    .summary = "Restore live files from a snapshot",
    .usage = "mox rollback [<id>]",
    .group = .general,
    .needs_context = true,
}, run);
