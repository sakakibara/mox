const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const mox = @import("../root.zig");
const scope = @import("scope.zig");
const prompt = @import("prompt.zig");
const style = @import("style.zig");
const commit_mod = @import("commit.zig");
const diff_mod = @import("diff.zig");

pub const Spec = struct {
    dry_run: cli.Flag(.{ .help = "report only, write nothing" }),
    force: cli.Flag(.{ .help = "overwrite drifted files" }),
    skip_scripts: cli.Flag(.{ .help = "compose and write files, run no scripts" }),
    defaults: cli.Flag(.{ .help = "never prompt: bind each unbound fact's default, decline the rest" }),
    paths: cli.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

pub fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    return applyImpl(ctx, a.force, a.dry_run, a.skip_scripts, a.defaults, a.paths);
}

/// `machine.state.captureDiag`, reporting a `ReservedFactName` (a custom fact
/// or `data/facts.toml` row colliding with a reserved axis or built-in
/// field) or a malformed `data/facts.toml` row the same way `mox facts` does,
/// instead of letting the bare error name reach main's generic handler --
/// apply is where users actually hit this, not just `mox facts`. Null return
/// means the caller already reported and should fail the run; any other
/// error still propagates.
fn captureOrReport(ctx: *app.Ctx, env: mox.env.Env, repo_dir: []const u8, private_dir: []const u8) !?mox.machine.state.MachineState {
    var diag: mox.machine.diag.Diag = .{};
    return mox.machine.state.captureDiag(ctx.alloc, ctx.io, env, repo_dir, private_dir, &diag) catch |e| switch (e) {
        error.ReservedFactName, error.ReservedFactsRowName => {
            try ctx.err.print("mox apply: {s}\n", .{
                diag.capture() orelse "a fact name collides with a reserved axis name",
            });
            return null;
        },
        error.MalformedFactsRow => {
            try ctx.err.print("mox apply: {s}\n", .{
                diag.capture() orelse "a data/facts.toml row is malformed",
            });
            return null;
        },
        else => return e,
    };
}

/// The apply pipeline, callable with explicit flags so `mox init --apply` can
/// run it right after a clone. `run` is the thin CLI wrapper over it. `paths`
/// limits the run to those managed files (empty: every file); when non-empty
/// the `.mox-exact` prune sweep is skipped entirely, since it reasons about
/// the whole tree and a scoped apply must touch only the named files.
pub fn applyImpl(ctx: *app.Ctx, force: bool, dry_run: bool, skip_scripts_arg: bool, defaults: bool, paths: []const []const u8) anyerror!u8 {
    var queued: std.ArrayList([]const u8) = .empty;
    const rc = try applyPass(ctx, force, dry_run, skip_scripts_arg, defaults, paths, &queued);
    if (queued.items.len == 0) return rc;
    // Deferred on purpose: the apply pass holds the state lock and the lock is
    // not re-entrant, so the commit the drift prompt queued can only run once
    // that pass has returned and released it. Committing a file leaves its
    // source matching live, so skipping its write above was correct.
    try ctx.out.print("\nCommitting {d} live edit(s) you chose to keep:\n", .{queued.items.len});
    const crc = try commit_mod.commitImpl(ctx, false, false, false, .auto, queued.items);
    return if (rc != 0 or crc != 0) 1 else 0;
}

fn applyPass(
    ctx: *app.Ctx,
    force: bool,
    dry_run: bool,
    skip_scripts_arg: bool,
    defaults_only: bool,
    paths: []const []const u8,
    queued_out: *std.ArrayList([]const u8),
) anyerror!u8 {
    const context = ctx.context.?;
    // Skip setup scripts (also implied by --dry-run) for fast, side-effect-
    // free file-only applies; scripts may install packages or hit the network.
    const skip_scripts = dry_run or skip_scripts_arg;

    const lk = (try lock_mod.acquireForCommand(ctx, "apply")) orelse return 1;
    defer lk.release();

    // Stale check-hook staging holds candidate cleartext (a crash skipped
    // the deferred cleanup); sweep before anything composes so a leftover
    // never survives past this run.
    mox.apply.run_scripts.sweepCheckDirs(ctx.alloc, ctx.io, context.paths.state_dir);

    // Drift resolution and the facts interview below share ONE buffered
    // stdin reader: two independent `File.Reader`s over the same real fd
    // would each buffer-consume bytes the other needed, breaking piped
    // input meant to script both in a single apply run.
    const scripted_input = app.stdin_override;
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const shared_stdin: *std.Io.Reader = scripted_input orelse &stdin_reader.interface;

    // Drift is resolved by asking only on a real terminal with nothing already
    // deciding the outcome. `--force` resolves it before the prompt is reached;
    // `--dry-run` writes nothing; a non-TTY keeps the skip-and-report contract
    // every script and CI run depends on.
    const interactive_drift = (scripted_input != null or tty.isInteractive(0)) and !force and !dry_run;
    var resolver: DriftResolver = .{
        .arena = ctx.alloc,
        .input = shared_stdin,
        .sty = .{ .on = style.enabled(tty.isInteractive(1), context.env.get(ctx.alloc, "NO_COLOR") != null, .auto) },
        .state_dir = context.paths.state_dir,
    };
    const resolver_opt: ?*DriftResolver = if (interactive_drift) &resolver else null;

    var m_state = (try captureOrReport(ctx, context.env, context.paths.repo_dir, context.paths.private_dir)) orelse return 1;
    var bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings_map);
    var bindings: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };
    for (m_state.skipped_fact_keys) |key| {
        try ctx.err.print("mox apply: facts.toml: {s}: not a string; ignored (a gate naming it will never match)\n", .{key});
    }
    if (m_state.hostname_fallback) {
        try ctx.err.writeAll("mox apply: hostname could not be determined; using \"unknown\"\n");
    }
    if (m_state.username_fallback) {
        try ctx.err.writeAll("mox apply: username could not be determined; using \"unknown\"\n");
    }
    if (try mox.machine.state.extrasNotice(ctx.alloc, ctx.io, m_state.xdg_config_home)) |notice| {
        try ctx.err.print("mox apply: {s}\n", .{notice});
    }
    if (try mox.machine.state.schemaLeftoverNotice(ctx.alloc, ctx.io, context.paths.repo_dir)) |notice| {
        try ctx.err.print("mox apply: {s}\n", .{notice});
    }

    // Config-space discovery: every custom fact ("dimension") the repo's own
    // sources consume, replacing the deleted hand-maintained schema file.
    // Its own per-file anomalies are reported loudly here rather than left
    // for a caller that never asks to see them. A structurally invalid
    // source tree (bad attributes.toml, an illegal own/check declaration, a
    // reserved axis name, ...) is the source-tree walk further below's
    // problem to diagnose with the offending file; discovery degrades to
    // "nothing found" here rather than pre-empting that richer report with
    // a bare error name.
    const discovery = mox.machine.dimensions.discover(ctx.alloc, ctx.io, context.paths.repo_dir) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => mox.machine.dimensions.Discovery{ .dimensions = &.{}, .scripts = &.{} },
    };
    for (discovery.diagnostics) |d| {
        try ctx.err.print("mox apply: {s}: <machine.{s}> is not a valid fact name; ignored\n", .{ d.path, d.name });
    }
    for (discovery.default_diagnostics) |dd| switch (dd) {
        .conflict => |c| try ctx.err.print(
            "mox apply: conflicting `# mox: default` for \"{s}\": {s}=\"{s}\" vs {s}=\"{s}\"\n",
            .{ c.name, c.first_source, c.first_value, c.second_source, c.second_value },
        ),
        .unclaimed => |u| try ctx.err.print(
            "mox apply: `# mox: default {s}=...` in {s} names a fact nothing else in the repo consumes; ignored\n",
            .{ u.name, u.source },
        ),
    };

    // Facts interview: resolve every eligible unbound dimension, persist the
    // answers, and re-capture so this apply already composes with them.
    // Interactive on a real terminal (or scripted stdin in a test); `mox
    // apply --defaults` never prompts and binds each dimension's agreed
    // default (or declines it); `--dry-run` and a plain non-interactive run
    // never persist -- there is no global refusal here, only a report: a
    // script that actually needs an unresolved fact is D3's problem to
    // block, not this pass's to refuse wholesale.
    const interactive_interview = (scripted_input != null or tty.isInteractive(0)) and !dry_run;
    const interview_mode: mox.machine.interview.Mode = blk: {
        if (dry_run) break :blk .report_only;
        if (defaults_only) break :blk .defaults;
        if (interactive_interview) break :blk .{ .interactive = .{ .input = shared_stdin, .out = ctx.out } };
        break :blk .report_only;
    };
    const interview = try mox.machine.interview.walkDimensions(ctx.alloc, discovery.dimensions, &bindings, interview_mode);
    if (interview.answers.len > 0) {
        try mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, interview.answers);
        m_state = (try captureOrReport(ctx, context.env, context.paths.repo_dir, context.paths.private_dir)) orelse return 1;
        bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        live_ctx = m_state.liveResolver(&bindings_map);
    }
    try mox.machine.interview.writeUnboundNotice(ctx.err, "mox apply: ", interview.unbound);

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    // Setup scripts inherit mox's environment plus MOX_REPO/MOX_STATE_DIR/
    // MOX_HOME and every fact as MOX_FACT_<UPPERCASE_NAME>, so a bootstrap
    // script can branch on the same facts that gate the file layer.
    const script_facts = try ctx.alloc.alloc(mox.apply.run_scripts.Fact, m_state.custom_facts.len);
    for (m_state.custom_facts, 0..) |f, i| script_facts[i] = .{ .name = f.name, .value = f.value };
    const script_env_result = try mox.apply.run_scripts.buildScriptEnv(
        ctx.alloc,
        context.env,
        context.paths.repo_dir,
        context.paths.state_dir,
        context.paths.home,
        script_facts,
    );
    var script_env = script_env_result.map;
    if (script_env_result.skipped.len > 0) {
        try ctx.err.print("mox apply: fact name(s) not representable as MOX_FACT_*, skipped from script env:", .{});
        for (script_env_result.skipped) |name| try ctx.err.print(" {s}", .{name});
        try ctx.err.writeAll("\n");
    }

    // Resolved once per apply run (not per checked partial file): an
    // unparseable override would otherwise warn once per file checked.
    const check_timeout_ms = mox.apply.run_scripts.checkTimeoutMs(&script_env, ctx.err);

    // $MOX_PATH: a private per-run file every setup script
    // gets, for naming an install directory mox would otherwise never see
    // (neither $PATH nor this repo's data/paths.toml registry). Created empty up front --
    // dies with the run, same private-temp-area treatment as the
    // MOX_CHECK_FILE/MOX_CHECK_DIR staging below.
    const mox_path_file = try mox.apply.mox_path.filePath(ctx.alloc, context.paths.state_dir);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mox_path_file, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(ctx.io, mox_path_file) catch {};
    try script_env.put("MOX_PATH", mox_path_file);
    var mox_path_reader: mox.apply.mox_path.Reader = .{ .path = mox_path_file };
    // Every directory named via $MOX_PATH so far this run: threaded into
    // check hooks below, which build their own env map straight from
    // `context.env` rather than sharing `script_env`, so they see the same
    // widened PATH later setup scripts do.
    var mox_path_dirs: std.ArrayList([]const u8) = .empty;

    // Pre-stage scripts run before any file compose+write. Used for
    // bootstrap (package install, mise/brew/scoop setup, etc.). Scripts
    // run on every apply; expensive work is guarded inside the script via
    // `mox trigger`.
    const pre_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts", "pre" });
    const pre_result = if (skip_scripts)
        mox.apply.run_scripts.Result{}
    else
        try mox.apply.run_scripts.runStage(ctx.alloc, ctx.io, pre_dir, &bindings, &script_env, ctx.out, ctx.err);

    // A pre-script may install a tool or create a directory a `data/facts.toml`
    // row derives a fact from. Re-capture so this same apply composes against
    // the machine as the bootstrap left it, not as it began -- the
    // first-apply staleness the design exists to eliminate.
    if (pre_result.ran > 0) {
        m_state = (try captureOrReport(ctx, context.env, context.paths.repo_dir, context.paths.private_dir)) orelse return 1;
        bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        live_ctx = m_state.liveResolver(&bindings_map);
    }
    // $MOX_PATH additions the pre stage named: fold into this run's probe
    // search space (on the FRESH state above, if it just recaptured) and
    // into PATH for every later script and check hook.
    try foldMoxPathAdditions(ctx, &mox_path_reader, m_state, &script_env, &mox_path_dirs);

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    var walk_diag: mox.source.tree.Diag = .{};
    const base_tree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, m_state.home, &walk_diag) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox apply: source tree not found at {s}\n", .{src_dir});
            try ctx.err.writeAll("Run 'mox init' first.\n");
            return 1;
        },
        error.OwnOnSymlink,
        error.OwnOnSeedOnce,
        error.OwnOnGenerator,
        error.OwnAndDisown,
        error.OwnPathOverlap,
        error.InvalidOwnPath,
        error.InvalidCheckDirective,
        error.CheckWithoutOwnership,
        => {
            try ctx.err.print("mox apply: ownership declaration: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
            });
            return 1;
        },
        error.UnknownAttributeKey,
        error.InvalidAttributeValue,
        => {
            try ctx.err.print("mox apply: attributes.toml: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.source.attributes.diagText(e),
            });
            return 1;
        },
        error.ReservedAxisName => {
            try ctx.err.print("mox apply: overlay filename: {s}: \"path\" is a reserved axis name; the path= axis no longer exists\n", .{
                walk_diag.capture() orelse "?",
            });
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
    var compose_failed: std.ArrayList([]const u8) = .empty;

    for (files, 0..) |file, file_i| {
        // `q` at a drift prompt stops the run: everything not yet resolved
        // is reported and counted drifted, and no further byte is written.
        if (resolver.aborted) {
            for (files[file_i..]) |rest| {
                counts.drift += 1;
                try ctx.err.print("  unresolved {s} (apply stopped at the drift prompt)\n", .{rest.live_path});
            }
            break;
        }
        // A head declaration the walk could not honor is this file's error
        // alone; everything else still applies.
        if (file.head_error.len > 0) {
            try ctx.err.print("  ERROR   {s} ({s})\n", .{ file.live_path, file.head_error });
            counts.fail += 1;
            continue;
        }

        // A GENERATOR (`for ... into`) fans out to N files instead of writing
        // its own path. Each output flows through the SAME per-file write path
        // as a normal file. Pruning the prior set and recording the manifest are
        // deferred to a second pass against the global keep set below.
        if (try applyGenerator(ctx, file, &bindings, &m_state, secrets, snap_id, force, dry_run, resolver_opt, &counts, &snapshotted, &produced, &regular_live, &gen_states, &ruleset, home)) continue;

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
            if (e == error.UnknownShell)
                try ctx.err.print("mox apply:   accepted shells: fish, zsh, bash, powershell\n", .{});
            if (e == error.ReservedAxisName)
                try ctx.err.writeAll("mox apply:   \"path\" is a reserved axis name; the path= axis no longer exists\n");
            if (diag.capture()) |cap|
                try ctx.err.print("mox apply:   failing item: {s}\n", .{cap});
            counts.fail += 1;
            // A file that fails to compose is undecided this run: it may be a
            // generator with a transient syntax slip, and the orphan sweep
            // must not treat its manifest as abandoned.
            try compose_failed.append(ctx.alloc, file.live_path);
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
            } else if (file.own_paths.len > 0) {
                try applyPartialFile(ctx, .{
                    .file = file,
                    .bytes = bytes,
                    .prov_items = prov.items,
                    .manager_secret = diag.manager_secret,
                    .snap_id = snap_id,
                    .force = force,
                    .dry_run = dry_run,
                    .skip_scripts = skip_scripts,
                    .resolver = resolver_opt,
                    .check_timeout_ms = check_timeout_ms,
                    .extra_path_dirs = mox_path_dirs.items,
                }, &counts, &snapshotted);
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
                    .resolver = resolver_opt,
                    .force = force,
                    .dry_run = dry_run,
                }, &counts, &snapshotted);
            }
        } else {
            counts.skip += 1;
            try ctx.out.print("  skipped {s} (axis-gated off)\n", .{file.live_path});
            try warnBadWholeFileGateAxis(ctx, file);
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
    // nothing and keeps its old manifest. After a drift-prompt abort the keep
    // set is incomplete, so pruning against it could delete live leaves --
    // and an aborted run must not remove anything anyway.
    for (gen_states.items) |g| {
        if (resolver.aborted) break;
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

    // Third pass: sweep manifests whose generator left the tree (source
    // deleted outside `mox remove`, or the file no longer parses as a
    // generator). Known = every walked generator this run, succeeded or
    // failed, plus any file with a head error (its nature is undecided this
    // run). Never on a scoped apply -- an unwalked generator is not an
    // orphan -- and never after a drift-prompt abort.
    if (!scoped and !resolver.aborted) {
        var known: std.StringHashMap(void) = .init(ctx.alloc);
        for (gen_states.items) |g| {
            try known.put(try ctx.alloc.dupe(u8, &mox.apply.generated.manifestName(g.live_path)), {});
        }
        for (files) |f| {
            if (f.head_error.len > 0) {
                try known.put(try ctx.alloc.dupe(u8, &mox.apply.generated.manifestName(f.live_path)), {});
            }
        }
        for (compose_failed.items) |p| {
            try known.put(try ctx.alloc.dupe(u8, &mox.apply.generated.manifestName(p)), {});
        }
        const swept = try mox.apply.generated.sweepOrphans(ctx.alloc, ctx.io, .{
            .state_dir = context.paths.state_dir,
            .snapshots_dir = context.paths.snapshots_dir,
            .snap_id = snap_id,
            .home = context.paths.home,
            .force = force,
            .dry_run = dry_run,
        }, &known, &keep_set, ctx.out, ctx.err);
        if (swept.removed > 0 and !dry_run) snapshotted = true;
        counts.fail += swept.refused;
    }

    // Exact-directory sweep: after every managed file is written, remove live
    // entries in `.mox-exact` directories that mox did not produce. The global
    // keep set is the managed set: a generated leaf (current, or a failed
    // generator's prior) is protected and never swept.
    var exact_result = mox.apply.exact.Result{};
    if (!scoped and tree.exact_dirs.len > 0 and !resolver.aborted) {
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

    if (snapshotted and !resolver.aborted) {
        const keep = blk: {
            const v = context.env.getAlloc(ctx.alloc, "MOX_SNAPSHOT_RETENTION") catch break :blk @as(usize, 10);
            const parsed = std.fmt.parseInt(usize, v, 10) catch parse_err: {
                try ctx.err.print("mox apply: MOX_SNAPSHOT_RETENTION={s}: not an integer; using default (10)\n", .{v});
                break :parse_err 10;
            };
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
    const post_result = if (skip_scripts or resolver.aborted)
        mox.apply.run_scripts.Result{}
    else
        try mox.apply.run_scripts.runStage(ctx.alloc, ctx.io, post_dir, &bindings, &script_env, ctx.out, ctx.err);
    // $MOX_PATH additions the post stage named: no script or check hook runs
    // after this in the same apply, but folding them in keeps the run's
    // bookkeeping (probe search space, PATH) consistent regardless of stage.
    try foldMoxPathAdditions(ctx, &mox_path_reader, m_state, &script_env, &mox_path_dirs);

    // Only name the interactive outcomes when they happened: an ordinary apply
    // prints the line it always has.
    const resolved: []const u8 = if (counts.overwritten > 0 or counts.queued > 0)
        try std.fmt.allocPrint(ctx.alloc, "{d} overwritten, {d} queued, ", .{ counts.overwritten, counts.queued })
    else
        "";

    if (dry_run) {
        try ctx.out.print(
            "\nDry run: {d} would be written, {d} unchanged, {d} skipped, {d} drifted, {d} failed; scripts not run\n",
            .{ counts.ok, counts.unchanged, counts.skip, counts.drift, counts.fail },
        );
    } else {
        try ctx.out.print(
            "\nApplied: {d} written, {d} unchanged, {d} skipped, {s}{d} drifted, {d} failed; scripts: {d} ran, {d} skipped, {d} failed\n",
            .{
                counts.ok,                        counts.unchanged,                         counts.skip,
                resolved,                         counts.drift,                             counts.fail,
                pre_result.ran + post_result.ran, pre_result.skipped + post_result.skipped, pre_result.failed + post_result.failed,
            },
        );
    }
    // An aborted run starts no commit flow: a `[c]` answered before the quit
    // is dropped loudly, its live edit untouched for the next run to route.
    if (resolver.aborted and resolver.queued.items.len > 0) {
        try ctx.out.print("  dropped {d} queued commit(s) (apply stopped); the live edits are untouched\n", .{resolver.queued.items.len});
    } else {
        queued_out.* = resolver.queued;
    }
    const total_fail = counts.fail + counts.drift + pre_result.failed + post_result.failed;
    return if (total_fail > 0) 1 else 0;
}

/// Fold whatever a just-finished stage appended to `$MOX_PATH` into
/// this run: widen `m_state`'s tool probe so a `tool=` gate sees it for the
/// rest of the run, and prepend it to `script_env`'s `PATH` so a later
/// script or check hook's own PATH lookups do too. `dirs_so_far` accumulates
/// across stages so it can be handed to a partial file's check hook, which
/// builds its own env map straight from `context.env` rather than sharing
/// `script_env`. A stage with nothing new (the common case) touches neither.
fn foldMoxPathAdditions(
    ctx: *app.Ctx,
    reader: *mox.apply.mox_path.Reader,
    m_state: mox.machine.state.MachineState,
    script_env: *std.process.Environ.Map,
    dirs_so_far: *std.ArrayList([]const u8),
) !void {
    const new_dirs = try reader.readNew(ctx.alloc, ctx.io, ctx.err);
    if (new_dirs.len == 0) return;
    if (m_state.tool_probe) |tp| tp.extend(new_dirs);
    try script_env.put("PATH", try mox.apply.mox_path.prependToPath(ctx.alloc, script_env.get("PATH"), new_dirs));
    try dirs_so_far.appendSlice(ctx.alloc, new_dirs);
}

/// A file just skipped as axis-gated off: when its whole-file gate names an
/// `os=`/`arch=` literal outside the closed set `machine.state.capture` can
/// ever bind (e.g. `macos` instead of `darwin`), warn -- such a gate can never
/// match any real machine, silently. Scoped to the whole-file gate alone; a
/// region gate or an overlay tuple is `mox doctor`'s repo-wide sweep to catch.
/// Best-effort: any failure to re-read or re-parse the file it just skipped
/// leaves the plain skip line as the only output.
fn warnBadWholeFileGateAxis(ctx: *app.Ctx, file: mox.source.tree.ManagedFile) !void {
    const expr = (mox.compose.wholeFileGateAxisExpr(ctx.alloc, ctx.io, file) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    }) orelse return;
    const ax = try mox.source.axes.ofAxisExpr(ctx.alloc, expr);
    for (ax.valuesFor("os")) |v| {
        if (mox.machine.state.isValidOsValue(v.value)) continue;
        const hint = if (std.mem.eql(u8, v.value, "macos")) " -- macos spells darwin" else "";
        try ctx.err.print("mox apply:   bad-axis-value os={s} (not a recognized os; darwin/linux/windows are the common ones{s})\n", .{ v.value, hint });
    }
    for (ax.valuesFor("arch")) |v| {
        if (mox.machine.state.isValidArchValue(v.value)) continue;
        try ctx.err.print("mox apply:   bad-axis-value arch={s} (not a recognized arch; aarch64/x86_64 are the common ones)\n", .{v.value});
    }
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
    /// Drift the user chose to discard, per file, at the prompt.
    overwritten: usize = 0,
    /// Drift the user chose to route back into source; committed after the
    /// apply pass releases the lock.
    queued: usize = 0,
};

const drift_choices = [_]prompt.Choice{
    .{ .key = "o", .label = "overwrite", .help = "overwrite -- discard the live edit, write the composed output" },
    .{ .key = "c", .label = "commit", .help = "commit -- route the live edit back into its source" },
    .{ .key = "d", .label = "diff", .help = "diff -- show what differs, then ask again" },
    .{ .key = "s", .label = "skip", .help = "skip -- leave it drifted" },
    .{ .key = "O", .label = "overwrite all", .help = "overwrite this and every remaining drifted file" },
    .{ .key = "S", .label = "skip all", .help = "skip this and every remaining drifted file" },
};

const DriftDecision = enum { overwrite, commit, skip, quit };

/// What `?` says `q` does at the drift prompt. Apply writes as it walks, so
/// the shared "write nothing" wording would be false here: files resolved
/// before the quit stay written.
const drift_quit_help = "stop the apply; this and every remaining file is left as it is";

/// Resolves one drifted file interactively. Sticky answers (`[O]`/`[S]`) are
/// remembered here, and `[c]` paths accumulate for the deferred commit pass --
/// apply holds the state lock, and the lock is not re-entrant, so commit cannot
/// run until apply is done with it.
const DriftResolver = struct {
    arena: std.mem.Allocator,
    input: *std.Io.Reader,
    sty: style.Style,
    state_dir: []const u8,
    sticky: ?DriftDecision = null,
    queued: std.ArrayList([]const u8) = .empty,
    aborted: bool = false,

    fn ask(
        self: *DriftResolver,
        ctx: *app.Ctx,
        live_path: []const u8,
        live: ?[]const u8,
        composed: []const u8,
        prov_items: []const mox.provenance.map.Segment,
    ) !DriftDecision {
        if (self.sticky) |d| return d;
        try ctx.err.print("  DRIFT   {s} (live file was edited)\n", .{live_path});
        // The header goes to stderr, the legend to stdout; on a shared
        // terminal only a flush here keeps the header above the prompt.
        try ctx.err.flush();
        while (true) {
            const line = try commit_mod.legend(self.arena, &drift_choices, 3, self.sty);
            switch (try prompt.askWith(.interactive, &drift_choices, 3, line, self.input, ctx.out, drift_quit_help)) {
                .chosen => |i| switch (i) {
                    0 => return .overwrite,
                    1 => {
                        try self.queued.append(self.arena, live_path);
                        return .commit;
                    },
                    2 => {
                        try self.showDiff(ctx, live_path, live orelse "", composed, prov_items);
                        continue;
                    },
                    3 => return .skip,
                    4 => {
                        self.sticky = .overwrite;
                        return .overwrite;
                    },
                    else => {
                        self.sticky = .skip;
                        return .skip;
                    },
                },
                // `q`, EOF, or exhausted attempts: stop the run rather than
                // silently picking an outcome for the remaining files.
                .abort, .abort_strict => {
                    self.aborted = true;
                    return .quit;
                },
                .report_only => return .skip,
            }
        }
    }

    /// Partial-file variant of `ask`: `[d]` shows the pre-rendered owned
    /// canonical diff, and on a secret-bearing record `[c]` is refused inline
    /// (commit would only skip the file later) and the prompt re-asks.
    fn askOwned(
        self: *DriftResolver,
        ctx: *app.Ctx,
        live_path: []const u8,
        drift_what: []const u8,
        diff_text: []const u8,
        refuse_commit: bool,
    ) !DriftDecision {
        if (self.sticky) |d| return d;
        try ctx.err.print("  DRIFT   {s} ({s} changed)\n", .{ live_path, drift_what });
        try ctx.err.flush();
        while (true) {
            const line = try commit_mod.legend(self.arena, &drift_choices, 3, self.sty);
            switch (try prompt.askWith(.interactive, &drift_choices, 3, line, self.input, ctx.out, drift_quit_help)) {
                .chosen => |i| switch (i) {
                    0 => return .overwrite,
                    1 => {
                        if (refuse_commit) {
                            try ctx.out.print("  cannot commit {s} (contains a secret; edit its source directly)\n", .{live_path});
                            continue;
                        }
                        try self.queued.append(self.arena, live_path);
                        return .commit;
                    },
                    2 => {
                        if (diff_text.len == 0) {
                            try ctx.out.writeAll("  (no visible difference; the owned changes are under secret paths)\n");
                        } else {
                            try ctx.out.writeAll(diff_text);
                        }
                        continue;
                    },
                    3 => return .skip,
                    4 => {
                        self.sticky = .overwrite;
                        return .overwrite;
                    },
                    else => {
                        self.sticky = .skip;
                        return .skip;
                    },
                },
                .abort, .abort_strict => {
                    self.aborted = true;
                    return .quit;
                },
                .report_only => return .skip,
            }
        }
    }

    /// The same rendering `mox diff` produces, so a secret resolved into the
    /// composed bytes is redacted here exactly as it is there.
    fn showDiff(
        self: *DriftResolver,
        ctx: *app.Ctx,
        live_path: []const u8,
        live: []const u8,
        composed: []const u8,
        prov_items: []const mox.provenance.map.Segment,
    ) !void {
        const a_lines = try mox.diff.lines.splitLines(self.arena, live);
        const b_lines = try mox.diff.lines.splitLines(self.arena, composed);
        const hunks = mox.diff.lines.diff(self.arena, a_lines, b_lines) catch |e| switch (e) {
            error.TooManyLines => {
                try ctx.out.print("  too large to diff\n", .{});
                return;
            },
            else => return e,
        };
        const b_secret = try diff_mod.secretMask(self.arena, b_lines.len, prov_items);
        const prior = try mox.provenance.map.read(self.arena, ctx.io, self.state_dir, live_path);
        const a_secret = if (prior) |m| try diff_mod.secretMask(self.arena, a_lines.len, m.segments) else &.{};
        const rendered = try diff_mod.renderFile(self.arena, live_path, a_lines, b_lines, hunks, a_secret, b_secret, self.sty);
        try ctx.out.writeAll(rendered);
    }
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
    /// Non-null on an interactive run: drift is resolved by asking, not by
    /// skipping. Null keeps the non-interactive contract (skip and report).
    resolver: ?*DriftResolver = null,
};

/// Write one composed regular file through the drift guard, pre-overwrite
/// snapshot, TOCTOU re-check, atomic write, and last-applied/provenance
/// records. Shared by the normal apply loop and every generator output, so the
/// 1:1 write/snapshot/state machinery is not duplicated.
fn applyRegularFile(ctx: *app.Ctx, in: RegularInput, counts: *Counts, snapshotted: *bool) !void {
    const context = ctx.context.?;
    // Kind guard BEFORE any open: a FIFO/socket/device at the live path would
    // block or misfire the read below, so it is reported and never opened.
    switch (mox.apply.write.guardLiveRead(ctx.io, in.live_path)) {
        .readable, .absent => {},
        .special => |k| {
            try ctx.err.print("mox apply: {s}: not a regular file ({s}); not written\n", .{ in.live_path, @tagName(k) });
            counts.fail += 1;
            return;
        },
    }
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
            const decision: DriftDecision = if (in.resolver) |r|
                try r.ask(ctx, in.live_path, live, in.bytes, in.prov_items)
            else
                .skip;
            switch (decision) {
                // Falls out of the switch to the write below, exactly as
                // `--force` does for this file alone.
                .overwrite => counts.overwritten += 1,
                .commit => {
                    counts.queued += 1;
                    try ctx.out.print("  queued {s} (will commit the live edit)\n", .{in.live_path});
                    return;
                },
                // The quit file itself stays unresolved: count it drifted so
                // the abort exits 1 even when it was the only drifted file.
                .quit => {
                    counts.drift += 1;
                    return;
                },
                .skip => {
                    counts.drift += 1;
                    if (in.resolver == null)
                        try ctx.err.print("  DRIFT   {s} (live file was edited; 'mox commit' it or re-run with --force)\n", .{in.live_path});
                    return;
                },
            }
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
                // A stale owned record from a formerly partial path would make
                // rollback withhold this file's whole-file restores forever.
                try mox.apply.applied.forgetOwned(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path);
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
        try mox.apply.applied.forgetOwned(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path);
        try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
        if (!contains_secret) {
            try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.bytes);
        }
        try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, in.live_path, in.prov_items);
    }
    counts.ok += 1;
    try ctx.out.print("  {s} {s}\n", .{ if (in.create_once) "seeded" else "wrote", in.live_path });
}

/// Inputs to `applyPartialFile`: the composed text plus everything the
/// partial pipeline needs from the managed file and the apply flags.
const PartialInput = struct {
    file: mox.source.tree.ManagedFile,
    bytes: []const u8,
    prov_items: []const mox.provenance.map.Segment,
    manager_secret: bool,
    snap_id: []const u8,
    force: bool,
    dry_run: bool,
    skip_scripts: bool,
    /// Non-null on an interactive run: owned drift is resolved by asking.
    /// Null keeps the non-interactive contract (skip and report).
    resolver: ?*DriftResolver = null,
    /// The check hook's wall-clock bound, resolved once per apply run.
    check_timeout_ms: i64,
    /// Directories named via `$MOX_PATH` by a stage that already ran
    /// this apply, prepended onto the check hook's PATH. Empty outside
    /// `mox apply` (rollback names no scripts, so it passes none).
    extra_path_dirs: []const []const u8 = &.{},
};

/// Run a partial file's `check` hook against `candidate`, materialized
/// in a private temp dir under the live basename. The child gets
/// MOX_CHECK_FILE and MOX_CHECK_DIR, runs with cwd at the repo root, and is
/// bounded by `timeout_ms` (the caller resolves MOX_CHECK_TIMEOUT_MS once per
/// run, not once per call, so a junk override warns exactly once). Returns
/// true on acceptance; any other outcome reports the refusal (with the
/// child's tail output), bumps `fail_count`, and returns false. Public
/// because rollback runs the same hook before re-patching a partial target.
/// `extra_path_dirs` is prepended onto the child's PATH -- empty for
/// rollback, which names no scripts of its own.
pub fn partialCheckAccepts(ctx: *app.Ctx, check_argv: []const []const u8, live_path: []const u8, candidate: []const u8, timeout_ms: i64, fail_count: *usize, extra_path_dirs: []const []const u8) !bool {
    const context = ctx.context.?;
    // Keyed by live path: the state lock serializes applies, so no two runs
    // race on it, and a crash's leftover is overwritten on the next apply.
    const path_hash = mox.apply.applied.contentHashHex(live_path);
    const check_dir = try std.fs.path.join(ctx.alloc, &.{
        context.paths.state_dir, try std.mem.concat(ctx.alloc, u8, &.{ "check-", path_hash[0..16] }),
    });
    // The temp dir holds only the candidate (a checker may list it); the
    // output capture sits beside it.
    const out_path = try std.mem.concat(ctx.alloc, u8, &.{ check_dir, ".out" });
    const cand_path = try std.fs.path.join(ctx.alloc, &.{ check_dir, std.fs.path.basename(live_path) });
    const materialized = blk: {
        // The staging dir holds candidate cleartext (possibly a resolved
        // secret): created private to the user, and re-tightened in case a
        // crashed run's leftover dir is being adopted.
        const perms: std.Io.File.Permissions = if (std.Io.File.Permissions.has_executable_bit) .fromMode(0o700) else .default_dir;
        _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, check_dir, perms) catch break :blk false;
        mox.apply.write.setMode(check_dir, 0o700) catch break :blk false;
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = cand_path, .data = candidate }) catch break :blk false;
        break :blk true;
    };
    defer std.Io.Dir.cwd().deleteTree(ctx.io, check_dir) catch {};
    defer std.Io.Dir.cwd().deleteFile(ctx.io, out_path) catch {};
    if (!materialized) {
        try ctx.err.print("  ERROR   {s} (check {s} could not run: candidate not materialized)\n", .{ live_path, check_argv[0] });
        fail_count.* += 1;
        return false;
    }

    var env_map = try context.env.createMap(ctx.alloc);
    try env_map.put("MOX_CHECK_FILE", cand_path);
    try env_map.put("MOX_CHECK_DIR", check_dir);
    if (extra_path_dirs.len > 0) {
        try env_map.put("PATH", try mox.apply.mox_path.prependToPath(ctx.alloc, env_map.get("PATH"), extra_path_dirs));
    }

    const res = mox.apply.run_scripts.runCheck(ctx.alloc, ctx.io, context.paths.repo_dir, check_argv, &env_map, out_path, timeout_ms) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} (check {s} could not run: {s})\n", .{ live_path, check_argv[0], @errorName(e) });
            fail_count.* += 1;
            return false;
        },
    };
    const why = res.refusal orelse return true;
    try ctx.err.print("  ERROR   {s} (check {s} refused the candidate: {s})\n", .{ live_path, check_argv[0], why });
    if (res.tail.len > 0) {
        try ctx.err.print("mox apply:   check output:\n{s}", .{res.tail});
        if (res.tail[res.tail.len - 1] != '\n') try ctx.err.writeAll("\n");
    }
    fail_count.* += 1;
    return false;
}

/// Write one partially owned file: compose is already done, so this runs
/// the declaration check, the per-path drift rule against the owned record,
/// the span splice with its invariant, the masked snapshot, and the
/// race-checked atomic write. Partial drift is skip-and-report (`--force`
/// reasserts); the interactive prompt arrives with the commit fold.
fn applyPartialFile(ctx: *app.Ctx, in: PartialInput, counts: *Counts, snapshotted: *bool) !void {
    const context = ctx.context.?;
    const partial_mod = mox.apply.partial;
    const canon_mod = mox.apply.canonical;
    const owned_mod = mox.apply.owned;
    const live_path = in.file.live_path;
    const own_paths = in.file.own_paths;
    // The walk only attaches own_paths to structured targets.
    const format = mox.source.format.formatOfPath(in.file.source_base_path).?;

    const mode: mox.apply.applied.Mode = if (in.file.ownership == .disown) .disown else .own;
    var pdiag: partial_mod.Diag = .{};

    const owned = partial_mod.OwnedDoc.parse(ctx.alloc, format, in.bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {s} (composed source does not parse as {s})\n", .{ live_path, @tagName(format) });
            counts.fail += 1;
            return;
        },
    };

    // The own-declaration leaf rule, in the file's mode: every composed leaf
    // must lie under a declared path (own), or no declared path may be
    // populated (disown), checked before live is read or touched.
    switch (mode) {
        .own => if (try partial_mod.undeclaredLeaf(ctx.alloc, &owned, own_paths)) |leaf| {
            try ctx.err.print("  ERROR   {s} (composed leaf {s} is outside the declared own paths)\n", .{ live_path, leaf });
            counts.fail += 1;
            return;
        },
        .disown => if (try partial_mod.populatedDisownPath(ctx.alloc, &owned, own_paths)) |spelled| {
            try ctx.err.print("  ERROR   {s} (composed source defines content under disowned path {s})\n", .{ live_path, spelled });
            counts.fail += 1;
            return;
        },
    }

    // Per-path secret granularity: the declared paths in own mode, the
    // extraction's top-level sections in disown mode.
    const secret_scope: []const mox.source.tree.OwnPath = switch (mode) {
        .own => own_paths,
        .disown => try canon_mod.topLevelPaths(ctx.alloc, &owned),
    };
    const secret_flags = partial_mod.secretPathFlags(ctx.alloc, format, in.bytes, secret_scope, in.prov_items, &pdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} (composed source: {s})\n", .{ live_path, pdiag.text() });
            counts.fail += 1;
            return;
        },
    };
    var any_secret = false;
    var secret_raws: std.ArrayList([]const u8) = .empty;
    for (secret_scope, secret_flags) |p, flagged| {
        if (flagged) {
            any_secret = true;
            try secret_raws.append(ctx.alloc, p.raw);
        }
    }

    // A symlinked live path runs the whole pipeline against its FINAL target:
    // the read follows the link, so the stat, the post-fsync recheck, and the
    // rename must address that same inode -- renaming onto the link path would
    // fork the file (a regular file over the link, stale bytes at the target).
    const live_target = mox.apply.write.resolvePartialLive(ctx.alloc, ctx.io, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => {
            try ctx.err.print("  ERROR   {s} (live path is a dangling symlink; fix or remove the link)\n", .{live_path});
            counts.fail += 1;
            return;
        },
    };
    // Kind guard BEFORE any open: a FIFO/socket/device at the (resolved) live
    // path would block the read below, so it is reported and never opened.
    switch (mox.apply.write.guardLiveRead(ctx.io, live_target)) {
        .readable, .absent => {},
        .special => |k| {
            try ctx.err.print("  ERROR   {s} (not a regular file: {s})\n", .{ live_path, @tagName(k) });
            counts.fail += 1;
            return;
        },
    }
    // Stat BEFORE the read: a write landing between the two moves the stat
    // identity past what the candidate was built from, so the post-fsync
    // recheck refuses (the safe direction) instead of missing it.
    const pre_stat = mox.apply.write.liveStat(ctx.io, live_target);
    const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, live_target, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            try ctx.err.print("mox apply: {s}: read failed: {s}\n", .{ live_path, @errorName(e) });
            counts.fail += 1;
            return;
        },
    };
    const live_stat: ?mox.apply.write.LiveStat = if (live != null) pre_stat else null;
    const live_text = live orelse "";

    const live_doc = partial_mod.OwnedDoc.parse(ctx.alloc, format, live_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {s} (live file does not parse as {s}; mox cannot patch what it cannot preserve)\n", .{ live_path, @tagName(format) });
            counts.fail += 1;
            return;
        },
    };

    const record = try mox.apply.applied.readOwned(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
    const record_paths: []const mox.source.tree.OwnPath = if (record) |r| try owned_mod.parseRawPaths(ctx.alloc, r.own_paths) else &.{};

    const composed_canon = switch (mode) {
        .own => try canon_mod.canonicalOwned(ctx.alloc, &owned, own_paths),
        .disown => try canon_mod.canonicalComplement(ctx.alloc, &owned, own_paths),
    };

    // A missing live file is a creation, classified as a plain write; an
    // existing one takes the drift rule against the owned record.
    const class: owned_mod.Class = if (live == null)
        .outdated
    else
        try owned_mod.classifyMode(ctx.alloc, mode, &owned, &live_doc, own_paths, record, record_paths);

    if (class == .drift and !in.force) {
        const drift_what = try owned_mod.driftWhat(ctx.alloc, class.drift);
        const resolver = in.resolver orelse {
            counts.drift += 1;
            try ctx.err.print("  DRIFT   {s} ({s} changed; 'mox commit' it or re-run with --force)\n", .{ live_path, drift_what });
            return;
        };
        // A secret-bearing record has no cleartext for commit to diff, so
        // `[c]` is refused inline rather than queued to be skipped later.
        const refuse_commit = record != null and record.?.secret;
        const diff_text = try ownedDriftDiff(ctx, resolver.sty, mode, live_path, &owned, &live_doc, own_paths, secret_scope, record, secret_flags);
        switch (try resolver.askOwned(ctx, live_path, drift_what, diff_text, refuse_commit)) {
            // Falls through to the write below, exactly as --force does for
            // this file alone.
            .overwrite => counts.overwritten += 1,
            .commit => {
                counts.queued += 1;
                try ctx.out.print("  queued {s} (will commit the live edit)\n", .{live_path});
                return;
            },
            .quit => {
                counts.drift += 1;
                return;
            },
            .skip => {
                counts.drift += 1;
                return;
            },
        }
    }
    // Live content already at the composed state (or a fresh target): the
    // drift rule is moot, exactly as whole-file `unchanged` precedes it.
    const live_matches = class == .clean;

    const record_current = blk: {
        const r = record orelse break :blk false;
        if (r.mode != mode) break :blk false;
        if (r.secret != any_secret) break :blk false;
        const cur_raws = try ctx.alloc.alloc([]const u8, own_paths.len);
        for (own_paths, cur_raws) |p, *o| o.* = p.raw;
        if (!owned_mod.sameRawSet(ctx.alloc, r.own_paths, cur_raws)) break :blk false;
        if (!owned_mod.sameRawSet(ctx.alloc, r.secret_paths, secret_raws.items)) break :blk false;
        if (r.secret) {
            const h = mox.apply.applied.contentHashHex(composed_canon);
            break :blk r.canonical_hash != null and std.mem.eql(u8, &h, &r.canonical_hash.?);
        }
        break :blk std.mem.eql(u8, r.canonical.?, composed_canon);
    };

    if (live_matches) {
        counts.unchanged += 1;
        if (in.dry_run or record_current) {
            try ctx.out.print("  unchanged {s}\n", .{live_path});
        } else {
            // Clean adoption: the live owned content is already the composed
            // content, so only the record is established; no byte changes.
            try writeOwnedRecord(ctx, live_path, mode, composed_canon, any_secret, own_paths, secret_raws.items);
            try ctx.out.print("  adopted {s} (live owned content matches the source)\n", .{live_path});
        }
        return;
    }

    if (in.dry_run) {
        counts.ok += 1;
        if (live == null) {
            try ctx.out.print("  would create {s}\n", .{live_path});
        } else {
            try ctx.out.print("  would write {s}\n", .{live_path});
        }
        return;
    }

    // A check-bearing file must never be installed unvalidated: under
    // --skip-scripts the hook does not run, so the write is skipped too.
    if (in.skip_scripts and in.file.check_argv.len > 0) {
        counts.skip += 1;
        try ctx.out.print("  skipped {s} (check skipped)\n", .{live_path});
        return;
    }

    const candidate = switch (mode) {
        .own => partial_mod.replaceOwned(ctx.alloc, format, live_text, own_paths, &owned, &pdiag),
        .disown => partial_mod.replaceDisowned(ctx.alloc, format, live_text, own_paths, in.bytes, &pdiag),
    } catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} ({s})\n", .{ live_path, pdiag.text() });
            counts.fail += 1;
            return;
        },
    };
    (switch (mode) {
        .own => partial_mod.verifyInvariant(ctx.alloc, format, live_text, candidate, own_paths, &owned, &pdiag),
        .disown => partial_mod.verifyDisownInvariant(ctx.alloc, format, live_text, candidate, own_paths, in.bytes, &owned, &pdiag),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} (invariant check failed: {s})\n", .{ live_path, pdiag.text() });
            counts.fail += 1;
            return;
        },
    };
    if (in.file.check_argv.len > 0) {
        if (!try partialCheckAccepts(ctx, in.file.check_argv, live_path, candidate, in.check_timeout_ms, &counts.fail, in.extra_path_dirs)) return;
    }

    if (live != null) {
        // Snapshot the whole pre-write live file, with values under
        // secret-bearing owned paths (recorded or current) masked so the
        // snapshot never stores a resolved secret.
        const recorded_secret: []const mox.source.tree.OwnPath = if (record) |r| try owned_mod.parseRawPaths(ctx.alloc, r.secret_paths) else &.{};
        var current_secret: std.ArrayList(mox.source.tree.OwnPath) = .empty;
        for (secret_scope, secret_flags) |p, flagged| {
            if (flagged) try current_secret.append(ctx.alloc, p);
        }
        const mask_paths = try owned_mod.unionPaths(ctx.alloc, recorded_secret, current_secret.items);
        const snap_content = partial_mod.maskSecretPaths(ctx.alloc, format, live_text, mask_paths) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MaskFailed => {
                try ctx.err.print("mox apply: {s}: snapshot masking failed, not overwriting\n", .{live_path});
                counts.fail += 1;
                return;
            },
        };
        mox.apply.snapshot.save(ctx.alloc, ctx.io, context.paths.snapshots_dir, in.snap_id, context.paths.home, live_path, snap_content) catch |e| {
            try ctx.err.print("mox apply: {s}: snapshot failed, not overwriting: {s}\n", .{ live_path, @errorName(e) });
            counts.fail += 1;
            return;
        };
        snapshotted.* = true;
    }

    const eff_mode = mox.apply.write.secretRestrictedMode(in.manager_secret, in.file.mode_explicit, in.file.mode, currentMode(ctx.io, live_target));
    mox.apply.write.writeAtomicPartial(ctx.io, live_target, candidate, eff_mode, live_stat) catch |e| switch (e) {
        error.LiveChangedDuringWrite => {
            try ctx.err.print("  CONFLICT {s} (changed underneath mox mid-apply; re-run 'mox apply')\n", .{live_path});
            counts.fail += 1;
            return;
        },
        else => {
            try ctx.err.print("mox apply: {s}: write failed: {s}\n", .{ live_path, @errorName(e) });
            counts.fail += 1;
            return;
        },
    };

    try writeOwnedRecord(ctx, live_path, mode, composed_canon, any_secret, own_paths, secret_raws.items);
    counts.ok += 1;
    try ctx.out.print("  {s} {s}\n", .{ if (live == null) "created" else "wrote", live_path });
}

/// The `[d]` rendering for a partial file's drift prompt: canonical
/// live-owned vs canonical composed-owned, masked per the union-secret rule
/// (the record's secret set plus any path the current compose resolved a
/// secret into) -- the same view `mox diff` shows for the file.
fn ownedDriftDiff(
    ctx: *app.Ctx,
    sty: style.Style,
    mode: mox.apply.applied.Mode,
    live_path: []const u8,
    owned: *const mox.apply.partial.OwnedDoc,
    live_doc: *const mox.apply.partial.OwnedDoc,
    own_paths: []const mox.source.tree.OwnPath,
    secret_scope: []const mox.source.tree.OwnPath,
    record: ?mox.apply.applied.OwnedRecord,
    secret_flags: []const bool,
) ![]const u8 {
    const canon_mod = mox.apply.canonical;
    const owned_mod = mox.apply.owned;
    var secret_paths: std.ArrayList(mox.source.tree.OwnPath) = .empty;
    if (record) |r| try secret_paths.appendSlice(ctx.alloc, try owned_mod.parseRawPaths(ctx.alloc, r.secret_paths));
    for (secret_scope, secret_flags) |p, flagged| {
        if (flagged and !owned_mod.pathInList(p.segments, secret_paths.items)) {
            try secret_paths.append(ctx.alloc, p);
        }
    }
    const spelled = try ctx.alloc.alloc([]const u8, secret_paths.items.len);
    for (secret_paths.items, spelled) |p, *s| s.* = try canon_mod.pathSpell(ctx.alloc, p.segments);

    const live_x = switch (mode) {
        .own => try canon_mod.canonicalOwned(ctx.alloc, live_doc, own_paths),
        .disown => try canon_mod.canonicalComplement(ctx.alloc, live_doc, own_paths),
    };
    const composed_x = switch (mode) {
        .own => try canon_mod.canonicalOwned(ctx.alloc, owned, own_paths),
        .disown => try canon_mod.canonicalComplement(ctx.alloc, owned, own_paths),
    };
    const a_text = try diff_mod.maskOwnedSections(ctx.alloc, live_x, spelled);
    const b_text = try diff_mod.maskOwnedSections(ctx.alloc, composed_x, spelled);
    if (std.mem.eql(u8, a_text, b_text)) return "";

    const a_lines = try mox.diff.lines.splitLines(ctx.alloc, a_text);
    const b_lines = try mox.diff.lines.splitLines(ctx.alloc, b_text);
    const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
        error.TooManyLines => return "",
        else => return e,
    };
    if (hunks.len == 0) return "";
    return diff_mod.renderOwnedFile(ctx.alloc, live_path, a_lines, b_lines, hunks, sty);
}

fn writeOwnedRecord(
    ctx: *app.Ctx,
    live_path: []const u8,
    mode: mox.apply.applied.Mode,
    composed_canon: []const u8,
    any_secret: bool,
    own_paths: []const mox.source.tree.OwnPath,
    secret_raws: []const []const u8,
) !void {
    const context = ctx.context.?;
    const raws = try ctx.alloc.alloc([]const u8, own_paths.len);
    for (own_paths, raws) |p, *o| o.* = p.raw;
    // The path is partial now: whole-file records and line provenance left by
    // a prior whole-file era are dead state no partial consumer reads.
    try mox.apply.applied.forgetWholeFile(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
    try mox.provenance.map.forget(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
    try mox.apply.applied.recordOwned(ctx.alloc, ctx.io, context.paths.state_dir, live_path, .{
        .mode = mode,
        .canonical = if (any_secret) null else composed_canon,
        .canonical_hash = if (any_secret) mox.apply.applied.contentHashHex(composed_canon) else null,
        .secret = any_secret,
        .own_paths = raws,
        .secret_paths = secret_raws,
    });
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
    bindings: *const mox.dsl.resolver.Resolver,
    m_state: *const mox.machine.state.MachineState,
    secrets: mox.compose.catB.SecretCtx,
    snap_id: []const u8,
    force: bool,
    dry_run: bool,
    resolver_opt: ?*DriftResolver,
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
        // A drift-prompt quit stops the fan-out too; the aborted run skips
        // the prune pass, so the unprocessed leaves are not swept.
        if (resolver_opt) |r| {
            if (r.aborted) break;
        }
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
            .resolver = resolver_opt,
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
    // An entry that became a special inode since the initial read counts as
    // "changed" (refuse) without opening it -- a FIFO read would block here.
    switch (mox.apply.write.guardLiveRead(io, live_path)) {
        .special => return false,
        .readable, .absent => {},
    }
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

/// Scripted drift-prompt input that, at the moment the prompt reads, checks
/// whether the DRIFT header already reached the stderr FILE (was flushed
/// past the writer's buffer), then answers `s`.
const FlushProbe = struct {
    reader: std.Io.Reader,
    io: std.Io,
    arena: std.mem.Allocator,
    err_path: []const u8,
    header_flushed: bool = false,
    done: bool = false,

    fn init(io: std.Io, arena: std.mem.Allocator, err_path: []const u8, buffer: []u8) FlushProbe {
        return .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .io = io,
            .arena = arena,
            .err_path = err_path,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        const self: *FlushProbe = @alignCast(@fieldParentPtr("reader", r));
        if (self.done) return error.EndOfStream;
        self.done = true;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.err_path, self.arena, .limited(1 << 20)) catch "";
        self.header_flushed = std.mem.indexOf(u8, content, "DRIFT") != null;
        const answer = "s\n";
        @memcpy(r.buffer[0..answer.len], answer);
        r.seek = 0;
        r.end = answer.len;
        return 0;
    }
};

test "DriftResolver.ask flushes the DRIFT header to stderr before the prompt reads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const err_path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "err" });

    const err_file = try std.Io.Dir.cwd().createFile(io, err_path, .{});
    defer err_file.close(io);
    // A buffer larger than the header: nothing reaches the file without an
    // explicit flush, exactly like the process stderr writer in main.
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(err_file, io, &err_buf);
    var out_aw: std.Io.Writer.Allocating = .init(a);

    var ctx: app.Ctx = .{ .alloc = a, .io = io, .out = &out_aw.writer, .err = &err_w.interface };
    var probe_buf: [64]u8 = undefined;
    var probe: FlushProbe = .init(io, a, err_path, &probe_buf);
    var resolver: DriftResolver = .{ .arena = a, .input = &probe.reader, .sty = .{ .on = false }, .state_dir = "" };

    const d = try resolver.ask(&ctx, "/home/me/.zshrc", null, "composed\n", &.{});
    try std.testing.expectEqual(DriftDecision.skip, d);
    // The header must be readable at the file BEFORE the prompt consumed
    // its answer, or a terminal shows the legend above the header.
    try std.testing.expect(probe.header_flushed);
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
        // `.other` also covers a FIFO/socket/device, whose "content" is not
        // readable bytes: like the exact sweep, a special inode carries
        // nothing recoverable, and opening a FIFO would block -- check the
        // kind first and read only a regular file.
        else => switch (mox.apply.write.guardLiveRead(io, live_path)) {
            .readable => std.Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024)) catch "",
            .absent, .special => "",
        },
    };
}

pub const command = app.command(Spec, .{
    .name = "apply",
    .summary = "Compose all managed files and write to live paths",
    .details = "--dry-run: report only; --force: overwrite drifted files; --skip-scripts: compose and write files, run no scripts.",
    .group = .general,
    .needs_context = true,
}, run);
