const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const mox = @import("../root.zig");
const scope = @import("scope.zig");

pub const Spec = struct {
    dry_run: cli.spec.Flag(.{ .help = "report only, write nothing" }),
    force: cli.spec.Flag(.{ .help = "overwrite drifted files" }),
    skip_scripts: cli.spec.Flag(.{ .help = "compose and write files, run no scripts" }),
    paths: cli.spec.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

pub fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    return applyImpl(ctx, a.force, a.dry_run, a.skip_scripts, a.paths);
}

/// The apply pipeline, callable with explicit flags so `mox init --apply` can
/// run it right after a clone. `run` is the thin CLI wrapper over it. `paths`
/// limits the run to those managed files (empty: every file); when non-empty
/// the `.mox-exact` prune sweep is skipped entirely, since it reasons about
/// the whole tree and a scoped apply must touch only the named files.
pub fn applyImpl(ctx: *app.Ctx, force: bool, dry_run: bool, skip_scripts_arg: bool, paths: []const []const u8) anyerror!u8 {
    const context = ctx.context.?;
    // Skip setup scripts (also implied by --dry-run) for fast, side-effect-
    // free file-only applies; scripts may install packages or hit the network.
    const skip_scripts = dry_run or skip_scripts_arg;

    const lk = (try lock_mod.acquireForCommand(ctx, "apply")) orelse return 1;
    defer lk.release();

    var m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    // Facts interview: prompt for schema-declared facts that are not yet
    // bound, persist the answers, and re-capture so this apply already
    // composes with them. Non-interactive runs with missing facts refuse
    // (composing without them would bake wrong values into live files).
    const schema = try mox.machine.interview.loadSchema(ctx.alloc, ctx.io, context.paths.repo_dir);
    if (schema.len > 0) {
        const interactive = tty.isInteractive(0);
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
        const input: ?*std.Io.Reader = if (interactive) &stdin_reader.interface else null;
        const outcome = try mox.machine.interview.walk(ctx.alloc, schema, &bindings, input, if (interactive) ctx.out else null);
        if (outcome.answers.len > 0) {
            try mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, outcome.answers);
            m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
            bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        }
        if (outcome.unanswered.len > 0) {
            try ctx.err.writeAll("mox apply: missing facts:");
            for (outcome.unanswered) |f| try ctx.err.print(" {s}", .{f.name});
            try ctx.err.writeAll("\nAnswer interactively (mox apply / mox facts) or set directly (mox facts set <name> <value>).\n");
            return 1;
        }
    }

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    // Setup scripts inherit mox's environment plus MOX_REPO/MOX_STATE_DIR/
    // MOX_HOME and every fact as MOX_FACT_<UPPERCASE_NAME>, so a bootstrap
    // script can branch on the same facts that gate the file layer.
    const script_facts = try ctx.alloc.alloc(mox.apply.run_scripts.Fact, m_state.custom_facts.len);
    for (m_state.custom_facts, 0..) |f, i| script_facts[i] = .{ .name = f.name, .value = f.value };
    const script_env = try mox.apply.run_scripts.buildScriptEnv(
        ctx.alloc,
        context.env,
        context.paths.repo_dir,
        context.paths.state_dir,
        context.paths.home,
        script_facts,
    );

    // Pre-stage scripts run before any file compose+write. Used for
    // bootstrap (package install, mise/brew/scoop setup, etc.). Scripts
    // run on every apply; expensive work is guarded inside the script via
    // `mox trigger`.
    const pre_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts", "pre" });
    const pre_result = if (skip_scripts)
        mox.apply.run_scripts.Result{}
    else
        try mox.apply.run_scripts.runStage(ctx.alloc, ctx.io, pre_dir, &bindings, &script_env, ctx.out, ctx.err);

    // A pre-script may install a tool or create a named path that the
    // `tool=`/`path=` axes gate on. Re-capture so this same apply composes
    // against the machine as the bootstrap left it, not as it began -- the
    // first-apply staleness the design exists to eliminate.
    if (pre_result.ran > 0) {
        m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
        bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    }

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox apply: source tree not found at {s}\n", .{src_dir});
            try ctx.err.writeAll("Run 'mox init' first.\n");
            return 1;
        },
        else => return e,
    };

    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
    const home = m_state.home;

    const scoped = paths.len > 0;
    var files: []const mox.source.tree.ManagedFile = tree.files;
    if (scoped) {
        var diag: scope.Diag = .{};
        files = scope.filterTree(ctx.alloc, ctx.io, tree.files, home, paths, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox apply: {s}: not managed\n", .{diag.capture().?});
                return 1;
            },
            else => return e,
        };
    }

    var counts: Counts = .{};

    const snap_id = try mox.apply.snapshot.freshId(ctx.alloc, ctx.io, context.paths.snapshots_dir);
    var snapshotted = false;

    // Every live path a generator produces this apply: added to the exact-sweep
    // managed set (so a generated leaf is not swept as unmanaged) and used to
    // detect a rendered path colliding with another producer.
    var produced: std.StringHashMap(void) = .init(ctx.alloc);
    // Regular managed targets, for the generator collision check.
    var regular_live: std.StringHashMap(void) = .init(ctx.alloc);
    for (files) |f| try regular_live.put(f.live_path, {});
    // Every generator seen this run (succeeded or failed), so pruning and manifest
    // recording happen AFTER all generators have composed. This makes the keep set
    // global and order-independent instead of "producers seen so far".
    var gen_states: std.ArrayList(GenState) = .empty;

    for (files) |file| {
        // A GENERATOR (`for ... into`) fans out to N files instead of writing
        // its own path. Each output flows through the SAME per-file write path
        // as a normal file. Pruning the prior set and recording the manifest are
        // deferred to a second pass against the global keep set below.
        if (try applyGenerator(ctx, file, &bindings, &m_state, secrets, snap_id, force, dry_run, &counts, &snapshotted, &produced, &regular_live, &gen_states, &ruleset, home)) continue;

        // A tracked source matching an ignore rule (itself or a containing
        // directory) is never composed or written.
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, file.live_path);
        if (ruleset.isPathIgnored(rel, false)) {
            try ctx.out.print("  skipping {s} (ignored)\n", .{file.live_path});
            continue;
        }

        // Seed-once files (recorded in `.mox/attributes.toml`) are written only
        // when the live path is absent. An existing one is left exactly as the
        // user has it and is never composed, drift-checked, or recorded.
        if (file.create_once) {
            const present = blk: {
                std.Io.Dir.cwd().access(ctx.io, file.live_path, .{}) catch break :blk false;
                break :blk true;
            };
            if (present) {
                counts.unchanged += 1;
                try ctx.out.print("  present {s} (seed-once)\n", .{file.live_path});
                continue;
            }
        }

        var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
        var diag: mox.compose.interp.Diag = .{};
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &prov, &diag) catch |e| {
            try ctx.err.print("mox apply: {s}: compose failed: {s}\n", .{ file.live_path, @errorName(e) });
            if (diag.capture()) |cap|
                try ctx.err.print("mox apply:   failing item: {s}\n", .{cap});
            counts.fail += 1;
            continue;
        };

        if (composed) |bytes| {
            if (file.is_symlink) {
                const target = std.mem.trim(u8, bytes, " \t\r\n");
                if (dry_run) {
                    counts.ok += 1;
                    try ctx.out.print("  would symlink {s} -> {s}\n", .{ file.live_path, target });
                    continue;
                }

                // Inspect the live path WITHOUT following the link, so an
                // existing regular file / dir / different symlink is protected
                // by the same drift + snapshot guard regular files get.
                const site = mox.apply.applied.inspectSymSite(ctx.io, ctx.alloc, file.live_path);
                const recorded_target = try mox.apply.applied.readSymlink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
                const disposition: mox.apply.applied.Disposition = switch (site) {
                    .absent => .fresh_write,
                    .symlink => |cur| blk: {
                        if (mox.apply.applied.sameSymlinkTarget(cur, target)) break :blk .unchanged;
                        if (recorded_target) |rt| if (mox.apply.applied.sameSymlinkTarget(rt, cur)) break :blk .safe_overwrite;
                        break :blk .drift;
                    },
                    // A regular file, directory, or special entry: mox never
                    // records a non-symlink here, so it is always drift.
                    .directory, .other => .drift,
                };

                if (disposition == .unchanged) {
                    counts.unchanged += 1;
                    try mox.apply.applied.recordSymlink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, target);
                    try ctx.out.print("  unchanged {s} -> {s}\n", .{ file.live_path, target });
                    continue;
                }
                if (disposition == .drift and !force) {
                    counts.drift += 1;
                    try ctx.err.print("  DRIFT   {s} (live entry was not written by mox; 'mox commit' it or re-run with --force)\n", .{file.live_path});
                    continue;
                }
                if (site == .directory) {
                    // Never unlink a live directory to plant a symlink.
                    try ctx.err.print("mox apply: {s}: refusing to replace a directory with a symlink\n", .{file.live_path});
                    counts.fail += 1;
                    continue;
                }
                // Snapshot whatever is there before destroying it, and refuse
                // the replace if the snapshot cannot be taken.
                if (disposition != .fresh_write) {
                    // A live symlink is snapshotted AS a symlink so rollback
                    // restores a link, not a file holding the target text.
                    const snap_res = switch (site) {
                        .symlink => |old_target| mox.apply.snapshot.saveSymlink(ctx.alloc, ctx.io, context.paths.snapshots_dir, snap_id, context.paths.home, file.live_path, old_target),
                        else => mox.apply.snapshot.save(ctx.alloc, ctx.io, context.paths.snapshots_dir, snap_id, context.paths.home, file.live_path, snapshotContentForSite(ctx.io, ctx.alloc, file.live_path, site)),
                    };
                    snap_res catch |e| {
                        try ctx.err.print("mox apply: {s}: snapshot failed, not replacing: {s}\n", .{ file.live_path, @errorName(e) });
                        counts.fail += 1;
                        continue;
                    };
                    snapshotted = true;
                }

                std.Io.Dir.cwd().deleteFile(ctx.io, file.live_path) catch {};
                if (std.fs.path.dirname(file.live_path)) |parent| {
                    std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
                }
                std.Io.Dir.cwd().symLink(ctx.io, target, file.live_path, .{}) catch |e| {
                    try ctx.err.print("mox apply: {s}: symlink failed: {s}\n", .{ file.live_path, @errorName(e) });
                    counts.fail += 1;
                    continue;
                };
                try mox.apply.applied.recordSymlink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, target);
                counts.ok += 1;
                try ctx.out.print("  symlinked {s} -> {s}\n", .{ file.live_path, target });
            } else {
                try applyRegularFile(ctx, .{
                    .live_path = file.live_path,
                    .bytes = bytes,
                    .prov_items = prov.items,
                    .manager_secret = diag.manager_secret,
                    .mode = file.mode,
                    .mode_explicit = file.mode_explicit,
                    .create_once = file.create_once,
                    .snap_id = snap_id,
                    .force = force,
                    .dry_run = dry_run,
                }, &counts, &snapshotted);
            }
        } else {
            counts.skip += 1;
            try ctx.out.print("  skipped {s} (axis-gated off)\n", .{file.live_path});
        }
    }

    // The GLOBAL keep/protected set, computed ONCE after every generator has
    // composed and written, so it does not depend on walk order: every current
    // generator output, every regular managed target, and every FAILED
    // generator's PRIOR leaves. A transient compose failure must delete nothing
    // -- its old files stay both on disk (protected here from the exact sweep)
    // and tracked (its manifest is left intact below). A leaf handed from one
    // generator to another is owned by whichever produces it this run, so the
    // generator that dropped it never prunes it.
    var keep_set: std.StringHashMap(void) = .init(ctx.alloc);
    {
        var rit = regular_live.keyIterator();
        while (rit.next()) |p| try keep_set.put(p.*, {});
        var pit = produced.keyIterator();
        while (pit.next()) |p| try keep_set.put(p.*, {});
        for (gen_states.items) |g| {
            if (g.succeeded) continue;
            for (g.prior) |leaf| try keep_set.put(leaf, {});
        }
    }

    // Second pass: prune each SUCCEEDED generator's dropped leaves against the
    // global keep, then record its current set. A failed generator prunes
    // nothing and keeps its old manifest.
    for (gen_states.items) |g| {
        if (!g.succeeded) continue;
        const prune = try mox.apply.generated.pruneStale(ctx.alloc, ctx.io, .{
            .state_dir = context.paths.state_dir,
            .snapshots_dir = context.paths.snapshots_dir,
            .snap_id = snap_id,
            .home = context.paths.home,
            .force = force,
            .dry_run = dry_run,
        }, g.prior, &keep_set, ctx.out, ctx.err);
        if (prune.removed > 0 and !dry_run) snapshotted = true;
        counts.fail += prune.refused;
        if (!dry_run) try mox.apply.generated.writeManifest(ctx.alloc, ctx.io, context.paths.state_dir, g.live_path, g.current);
    }

    // Exact-directory sweep: after every managed file is written, remove live
    // entries in `.mox-exact` directories that mox did not produce. The global
    // keep set is the managed set: a generated leaf (current, or a failed
    // generator's prior) is protected and never swept.
    var exact_result = mox.apply.exact.Result{};
    if (!scoped and tree.exact_dirs.len > 0) {
        var managed_live: std.ArrayList([]const u8) = .empty;
        var kit = keep_set.keyIterator();
        while (kit.next()) |p| try managed_live.append(ctx.alloc, p.*);
        exact_result = try mox.apply.exact.enforce(
            ctx.alloc,
            ctx.io,
            tree.exact_dirs,
            managed_live.items,
            .{
                .state_dir = context.paths.state_dir,
                .snapshots_dir = context.paths.snapshots_dir,
                .snap_id = snap_id,
                .home = context.paths.home,
                .force = force,
                .dry_run = dry_run,
            },
            ctx.out,
            ctx.err,
            &ruleset,
            context.paths.home,
        );
        if (exact_result.removed > 0 and !dry_run) snapshotted = true;
        counts.fail += exact_result.refused;
    }

    if (snapshotted) {
        const keep = blk: {
            const v = context.env.getAlloc(ctx.alloc, "MOX_SNAPSHOT_RETENTION") catch break :blk @as(usize, 10);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 10;
            // Never prune below 1: this run just took a snapshot, and deleting
            // it in the same apply would leave the write non-rollbackable.
            break :blk @max(@as(usize, 1), parsed);
        };
        mox.apply.snapshot.prune(ctx.alloc, ctx.io, context.paths.snapshots_dir, keep) catch |e| {
            try ctx.err.print("mox apply: snapshot prune failed: {s}\n", .{@errorName(e)});
        };
    }

    // Post-stage scripts run after all files are written. Used for
    // service reloads, theme cache rebuilds, fish_update_completions, etc.
    const post_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts", "post" });
    const post_result = if (skip_scripts)
        mox.apply.run_scripts.Result{}
    else
        try mox.apply.run_scripts.runStage(ctx.alloc, ctx.io, post_dir, &bindings, &script_env, ctx.out, ctx.err);

    if (dry_run) {
        try ctx.out.print(
            "\nDry run: {d} would be written, {d} unchanged, {d} skipped, {d} drifted, {d} failed; scripts not run\n",
            .{ counts.ok, counts.unchanged, counts.skip, counts.drift, counts.fail },
        );
    } else {
        try ctx.out.print(
            "\nApplied: {d} written, {d} unchanged, {d} skipped, {d} drifted, {d} failed; scripts: {d} ran, {d} skipped, {d} failed\n",
            .{
                counts.ok,                                counts.unchanged,                       counts.skip,
                counts.drift,                             counts.fail,                            pre_result.ran + post_result.ran,
                pre_result.skipped + post_result.skipped, pre_result.failed + post_result.failed,
            },
        );
    }
    const total_fail = counts.fail + counts.drift + pre_result.failed + post_result.failed;
    return if (total_fail > 0) 1 else 0;
}

/// One generator's state carried from the compose+write pass to the deferred
/// prune/manifest pass. `current` is the set produced this run (empty when the
/// generator failed); `prior` is its recorded manifest. A failed generator is
/// pruned against nothing and its manifest is left intact.
const GenState = struct {
    live_path: []const u8,
    prior: []const []const u8,
    current: []const []const u8,
    succeeded: bool,
};

/// Apply-loop tally, threaded into the per-file writer so a generator's N
/// outputs update the same counters as a normal file.
const Counts = struct {
    ok: usize = 0,
    unchanged: usize = 0,
    skip: usize = 0,
    drift: usize = 0,
    fail: usize = 0,
};

/// Inputs to `applyRegularFile`: everything the per-file write path needs that
/// differs between a normal managed file and one generator output.
const RegularInput = struct {
    live_path: []const u8,
    bytes: []const u8,
    prov_items: []const mox.provenance.map.Segment,
    manager_secret: bool,
    mode: u32,
    mode_explicit: bool,
    create_once: bool,
    snap_id: []const u8,
    force: bool,
    dry_run: bool,
};

/// Write one composed regular file through the drift guard, pre-overwrite
/// snapshot, TOCTOU re-check, atomic write, and last-applied/provenance
/// records. Shared by the normal apply loop and every generator output, so the
/// 1:1 write/snapshot/state machinery is not duplicated.
fn applyRegularFile(ctx: *app.Ctx, in: RegularInput, counts: *Counts, snapshotted: *bool) !void {
    const context = ctx.context.?;
    // A file whose composition inlined a resolved secret must NOT have its
    // cleartext cached: the applied-content drift cache and snapshots are
    // secret-aware. The hash record is still stored (preimage-resistant).
    const contains_secret = mox.provenance.map.hasSecret(in.prov_items);
    // A dedicated-manager (op://|pass://) secret auto-restricts the file to
    // 0600 when it has no explicit mode. An explicit attribute mode overrides.
    const eff_mode = mox.apply.write.secretRestrictedMode(in.manager_secret, in.mode_explicit, in.mode, currentMode(ctx.io, in.live_path));
    const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, in.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            try ctx.err.print("mox apply: {s}: read failed: {s}\n", .{ in.live_path, @errorName(e) });
            counts.fail += 1;
            return;
        },
    };
    const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path);

    const disposition = mox.apply.applied.classify(recorded, live, in.bytes);
    switch (disposition) {
        .drift => if (!in.force) {
            counts.drift += 1;
            try ctx.err.print("  DRIFT   {s} (live file was edited; 'mox commit' it or re-run with --force)\n", .{in.live_path});
            return;
        },
        .unchanged => {
            counts.unchanged += 1;
            if (!in.dry_run) {
                // Content matches, so writeAtomic never runs; heal drift of an
                // EXPLICITLY attributed mode. A default mode is left alone.
                if ((in.mode_explicit or in.manager_secret) and !liveIsSymlink(ctx.io, in.live_path)) {
                    mox.apply.write.setMode(in.live_path, eff_mode) catch |e| {
                        try ctx.err.print("mox apply: {s}: could not enforce mode: {s}\n", .{ in.live_path, @errorName(e) });
                    };
                }
                try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
                if (!contains_secret) {
                    try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
                }
                try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.prov_items);
            }
            try ctx.out.print("  unchanged {s}\n", .{in.live_path});
            return;
        },
        .fresh_write, .safe_overwrite => {},
    }

    if (in.dry_run) {
        counts.ok += 1;
        try ctx.out.print("  would write {s}\n", .{in.live_path});
        return;
    }
    // About to replace existing content: snapshot it first (secret lines
    // redacted), and refuse the overwrite if the snapshot cannot be taken.
    if (disposition != .fresh_write) {
        const snap_content = try redactedPriorContent(ctx, in.live_path, live.?);
        mox.apply.snapshot.save(ctx.alloc, ctx.io, context.paths.snapshots_dir, in.snap_id, context.paths.home, in.live_path, snap_content) catch |e| {
            try ctx.err.print("mox apply: {s}: snapshot failed, not overwriting: {s}\n", .{ in.live_path, @errorName(e) });
            counts.fail += 1;
            return;
        };
        snapshotted.* = true;
    }
    // TOCTOU guard: re-read right before the write to detect an interleaved
    // external edit that is not in the snapshot.
    if (!liveMatchesInitial(ctx.io, ctx.alloc, in.live_path, live)) {
        try ctx.err.print("  CONFLICT {s} (changed underneath mox mid-apply; re-run 'mox apply')\n", .{in.live_path});
        counts.fail += 1;
        return;
    }
    mox.apply.write.writeAtomic(ctx.io, in.live_path, in.bytes, eff_mode) catch |e| {
        try ctx.err.print("mox apply: {s}: write failed: {s}\n", .{ in.live_path, @errorName(e) });
        counts.fail += 1;
        return;
    };
    if (!in.create_once) {
        try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
        if (!contains_secret) {
            try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
        }
        try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.prov_items);
    }
    counts.ok += 1;
    try ctx.out.print("  {s} {s}\n", .{ if (in.create_once) "seeded" else "wrote", in.live_path });
}

/// Apply a GENERATOR file, or report it is not one. Returns false when `file`
/// is a normal managed file (the caller composes it the usual way). Returns
/// true after fanning out: each produced output is written through
/// `applyRegularFile` and the generator's state is recorded in `gen_states` for
/// the deferred prune/manifest pass. An output whose rendered path matches an
/// ignore rule is skipped individually (not written, not kept) while its
/// siblings still materialize. A rendered path colliding with a regular
/// managed target or another generator's output, escaping the target dir via a
/// symlinked parent, or a compose failure, fails that generator whole (it
/// produces nothing, prunes nothing, and its prior leaves stay protected).
fn applyGenerator(
    ctx: *app.Ctx,
    file: mox.source.tree.ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    m_state: *const mox.machine.state.MachineState,
    secrets: mox.compose.catB.SecretCtx,
    snap_id: []const u8,
    force: bool,
    dry_run: bool,
    counts: *Counts,
    snapshotted: *bool,
    produced: *std.StringHashMap(void),
    regular_live: *std.StringHashMap(void),
    gen_states: *std.ArrayList(GenState),
    ruleset: *const mox.source.ignore.match.RuleSet,
    home: []const u8,
) !bool {
    var diag: mox.compose.interp.Diag = .{};
    const gen = mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, bindings, m_state, secrets, &diag) catch |e| {
        try ctx.err.print("mox apply: {s}: generator failed: {s}\n", .{ file.live_path, @errorName(e) });
        if (diag.capture()) |cap|
            try ctx.err.print("mox apply:   failing item: {s}\n", .{cap});
        counts.fail += 1;
        // It IS a generator (compose recognized and then failed): consume it so
        // the caller does not also try to compose it as a normal file. Record it
        // as failed so its prior leaves are protected and its manifest is kept.
        try recordFailedGenerator(ctx, file, gen_states);
        return true;
    };
    const outputs = gen orelse return false;

    const base_dir = std.fs.path.dirname(file.live_path) orelse file.live_path;

    // Guards, run BEFORE any write: a generated path equal to a regular managed
    // target or another generator's output this apply, or one that escapes the
    // target dir through a pre-existing symlinked parent component, aborts the
    // whole generator so no half-owned or misplaced set is written.
    for (outputs) |o| {
        const collides_regular = regular_live.contains(o.live_path) and !std.mem.eql(u8, o.live_path, file.live_path);
        if (collides_regular or produced.contains(o.live_path)) {
            try ctx.err.print("mox apply: {s}: generated path collides with another managed file: {s}\n", .{ file.live_path, o.live_path });
            counts.fail += 1;
            try recordFailedGenerator(ctx, file, gen_states);
            return true;
        }
        if (generatedParentEscapes(ctx.io, base_dir, o.live_path)) {
            try ctx.err.print("mox apply: {s}: generated path escapes the target dir through a symlink: {s}\n", .{ file.live_path, o.live_path });
            counts.fail += 1;
            try recordFailedGenerator(ctx, file, gen_states);
            return true;
        }
    }

    // Current produced set for the manifest + global keep-set.
    var current: std.ArrayList([]const u8) = .empty;
    for (outputs) |o| {
        // A generated output whose rendered path matches an ignore rule (itself
        // or a containing directory) is outside mox's management, same as any
        // other source: never written, never added to the keep set.
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, o.live_path);
        if (ruleset.isPathIgnored(rel, false)) {
            try ctx.out.print("  skipping {s} (ignored)\n", .{o.live_path});
            continue;
        }
        try current.append(ctx.alloc, o.live_path);
        try produced.put(o.live_path, {});
        try applyRegularFile(ctx, .{
            .live_path = o.live_path,
            .bytes = o.content,
            .prov_items = o.prov,
            .manager_secret = o.manager_secret,
            .mode = 0o644,
            .mode_explicit = false,
            .create_once = false,
            .snap_id = snap_id,
            .force = force,
            .dry_run = dry_run,
        }, counts, snapshotted);
    }

    const prior = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, ctx.context.?.paths.state_dir, file.live_path);
    try gen_states.append(ctx.alloc, .{
        .live_path = file.live_path,
        .prior = prior,
        .current = try current.toOwnedSlice(ctx.alloc),
        .succeeded = true,
    });
    return true;
}

/// Record a generator that could not produce a valid set this run (compose
/// error, path collision, or symlink escape). It prunes nothing; its prior
/// leaves feed the global keep set so the sweep and other prunes leave them be.
fn recordFailedGenerator(ctx: *app.Ctx, file: mox.source.tree.ManagedFile, gen_states: *std.ArrayList(GenState)) !void {
    const prior = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, ctx.context.?.paths.state_dir, file.live_path);
    try gen_states.append(ctx.alloc, .{ .live_path = file.live_path, .prior = prior, .current = &.{}, .succeeded = false });
}

/// Reject a generated output whose path would reach outside the generator's
/// target dir through a pre-existing symlinked directory component. `keyEscapes`
/// is textual; the rendered tail is DATA-DERIVED, so a component like `sub` that
/// is a symlink to `/etc` would land the write on `/etc/...`. Walk each ancestor
/// directory below `base_dir` with a no-follow stat and reject any symlink.
fn generatedParentEscapes(io: std.Io, base_dir: []const u8, live_path: []const u8) bool {
    if (!std.mem.startsWith(u8, live_path, base_dir)) return true;
    var i = base_dir.len;
    while (i < live_path.len and std.fs.path.isSep(live_path[i])) i += 1;
    while (i < live_path.len) : (i += 1) {
        if (!std.fs.path.isSep(live_path[i])) continue;
        const st = std.Io.Dir.cwd().statFile(io, live_path[0..i], .{ .follow_symlinks = false }) catch continue;
        if (st.kind == .sym_link) return true;
    }
    return false;
}

/// The prior live content to snapshot before an overwrite, with any secret
/// lines redacted using the last-persisted provenance for this path. mox only
/// authored a secret line where it recorded provenance, so an absent or
/// non-secret provenance leaves the content unchanged.
fn redactedPriorContent(ctx: *app.Ctx, live_path: []const u8, content: []const u8) ![]const u8 {
    const context = ctx.context.?;
    const prior = (try mox.provenance.map.read(ctx.alloc, ctx.io, context.paths.state_dir, live_path)) orelse return content;
    return mox.provenance.map.redactSecretLines(ctx.alloc, content, prior.segments);
}

/// True when the live path's CURRENT content still equals `initial` (the copy
/// apply read, classified, and snapshotted). Used just before a write to detect
/// an interleaved external edit. An unreadable path or a re-read error counts as
/// "changed" (conservative: refuse the write). Absent-and-was-absent matches.
fn liveMatchesInitial(io: std.Io, arena: std.mem.Allocator, live_path: []const u8, initial: ?[]const u8) bool {
    const now: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return false,
    };
    if (initial == null and now == null) return true;
    if (initial == null or now == null) return false;
    return std.mem.eql(u8, initial.?, now.?);
}

test "liveMatchesInitial: detects an interleaved external change before a write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const p = try std.fs.path.join(a, &.{ base, "f" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "orig\n" });

    // Unchanged since the initial read -> safe to write.
    try std.testing.expect(liveMatchesInitial(io, a, p, "orig\n"));
    // An external writer changed it -> refuse the write.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "external edit\n" });
    try std.testing.expect(!liveMatchesInitial(io, a, p, "orig\n"));
    // Absent and was absent (a fresh-write target that stayed absent).
    const gone = try std.fs.path.join(a, &.{ base, "gone" });
    try std.testing.expect(liveMatchesInitial(io, a, gone, null));
    // Was absent, now a file appeared -> refuse (do not clobber it).
    try std.testing.expect(!liveMatchesInitial(io, a, p, null));
}

/// The current unix mode (permission bits) of `live_path`, or null when it is
/// absent or the platform has no mode bits. Lets an auto-restricted secret file
/// respect a mode the user already made at least as private.
fn currentMode(io: std.Io, live_path: []const u8) ?u32 {
    if (!std.Io.File.Permissions.has_executable_bit) return null;
    const st = std.Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch return null;
    return @intCast(st.permissions.toMode() & 0o777);
}

/// True when `live_path` is itself a symlink (no-follow). chmod follows links,
/// so the caller skips mode enforcement here rather than touch the link target.
fn liveIsSymlink(io: std.Io, live_path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// Recoverable bytes to snapshot before replacing a live entry with a symlink:
/// a regular file's content, or a link's target string. Best-effort; an
/// unreadable regular file yields its own snapshot-empty marker only after the
/// caller has already decided to proceed under --force.
fn snapshotContentForSite(io: std.Io, arena: std.mem.Allocator, live_path: []const u8, site: mox.apply.applied.SymSite) []const u8 {
    return switch (site) {
        .symlink => |target| target,
        else => std.Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024)) catch "",
    };
}

pub const command = app.command(Spec, .{
    .name = "apply",
    .summary = "Compose all managed files and write to live paths",
    .details = "--dry-run: report only; --force: overwrite drifted files; --skip-scripts: compose and write files, run no scripts.",
    .group = .general,
    .needs_context = true,
}, run);
