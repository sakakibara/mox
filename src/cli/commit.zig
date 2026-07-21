//! `mox commit`: route user edits of live files back into their sources.
//!
//! A live file that no longer matches what mox last wrote to it (true drift)
//! is diffed against the last-applied content. Each changed hunk is mapped,
//! through the provenance recorded at apply time, back to the source that
//! produced it: a base line to `src/`, a fragment line to its fragment file,
//! a private-layer line to the private file (NEVER repo src), a loop row to
//! its data source. Secret, interpolated, structural-merge, and straddling
//! hunks have no safe automatic route and are reported as manual.
//!
//! On a TTY each routed hunk is confirmed `[Y/n/m]`; `--yes` takes the
//! defaults; `--dry-run` and a non-TTY without `--yes` only report (exit 1
//! when hunks remain); `--abort-on-prompt` exits 2 for a prompt that would have
//! been needed, terminal or not. All writes happen after every prompt, so
//! aborting writes nothing. After a file's sources are edited it is recomposed:
//! only when the result is byte-identical to the live file, and no
//! configuration the user did not choose changed, is the applied record
//! advanced. A file that fails either check is not committed, and "not
//! committed" means every source it wrote is restored -- including a fragment
//! and region directory a narrowing synthesized.
//!
//! A manual hunk, and a hunk the user deliberately declines (`n`) or skips
//! (`s`), are differences the recompose is EXPECTED to keep: both stay in the
//! live file by design, so a file that has one can never recompose to live
//! however well its other hunks routed. Those routed edits stand, the applied
//! record does not advance (the rest is still real drift), and the report
//! says what is left. A hunk the tool could not route to the candidate the
//! user picked (no automatic path, a hazard) is not something the user asked
//! for, and still rolls the whole file's routing back.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const prompt = @import("prompt.zig");
const scope = @import("scope.zig");
const mox = @import("../root.zig");

const Io = std.Io;
const Segment = mox.provenance.map.Segment;
const Hunk = mox.diff.lines.Hunk;
const candidates = mox.classify.candidates;
const impact = mox.classify.impact;
const config_space = mox.classify.config_space;
const Configuration = config_space.Configuration;

const max_file_bytes: usize = 64 * 1024 * 1024;

const Field = struct { name: []const u8, value: []const u8 };

/// A line-level edit to one physical source file (base / fragment / private).
/// `private` marks an edit routed to a private-layer source: the coupling graph
/// only indexes shared base sources, so a private edit's rename could only ever
/// sync a private-authored token INTO the shared repo -- never allowed.
const LineEdit = struct {
    path: []const u8,
    start: u32,
    del: u32,
    new_lines: []const []const u8,
    private: bool = false,
};

/// A field update to one row of a TOML data source (loop origin).
const RowEdit = struct {
    data_source: []const u8,
    stem: []const u8,
    row: u32,
    fields: []const Field,
};

/// The routing decision for a single hunk. `shared` on a line route marks a
/// base-file or universal-fragment origin (subject to impact classification);
/// an axis-gated fragment or private-layer origin is not shared.
const Route = union(enum) {
    line: struct { edit: LineEdit, desc: []const u8, shared: bool },
    row: struct { edit: RowEdit, desc: []const u8 },
    manual: []const u8,
};

/// Everything the per-hunk classifier needs. Grouped so the shared-origin
/// pipeline (impact analysis, candidate prompt, verification allowlist) can be
/// factored out of the main routing loop.
const ClassCtx = struct {
    arena: std.mem.Allocator,
    io: Io,
    this_bindings: *const std.StringHashMap([]const u8),
    m_state: *const mox.machine.state.MachineState,
    secrets: mox.compose.catB.SecretCtx,
    hostname: []const u8,
    stdout: *Io.Writer,
    input: *Io.Reader,
    ask_mode: prompt.Mode,
    report_mode: bool,
    /// What the narrowings accepted earlier in this run will create.
    claims: *Claims,
};

/// A region synthesis to materialize after all prompts.
const SynthDecision = struct {
    plan: mox.classify.synth.Plan,
    base_abs: []const u8,
    /// Configuration labels this narrowing is allowed to change.
    allowed: []const []const u8,
};

/// The regions and fragments the narrowings ACCEPTED SO FAR IN THIS RUN will
/// create. `synth.hazardOf` sees only what predates the run, so it is blind to
/// them: without this, a second narrowing of the same file to the same axis
/// passes every check and then overwrites the first one's region and fragment
/// -- two regions of one name are unrepresentable, which is exactly what the
/// region hazard exists to prevent.
const Claims = struct {
    regions: std.ArrayList(Region),
    fragments: std.ArrayList([]const u8),

    const Region = struct { base_abs: []const u8, name: []const u8 };

    const empty: Claims = .{ .regions = .empty, .fragments = .empty };

    fn add(c: *Claims, arena: std.mem.Allocator, base_abs: []const u8, name: []const u8, fragment: []const u8) !void {
        try c.regions.append(arena, .{ .base_abs = base_abs, .name = name });
        try c.fragments.append(arena, fragment);
    }

    /// Why narrowing `base_abs` to a `name` region writing `fragment` collides
    /// with a narrowing this run already accepted, or null when it is free.
    fn hazard(c: Claims, arena: std.mem.Allocator, base_abs: []const u8, name: []const u8, fragment: []const u8) !?[]const u8 {
        for (c.regions.items) |r| {
            if (!std.mem.eql(u8, r.base_abs, base_abs)) continue;
            if (!std.mem.eql(u8, r.name, name)) continue;
            return try std.fmt.allocPrint(
                arena,
                "another edit in this commit already narrows this file to a region named \"{s}\", which would pick up the new fragment too",
                .{name},
            );
        }
        for (c.fragments.items) |f| {
            if (!std.mem.eql(u8, f, fragment)) continue;
            return try std.fmt.allocPrint(
                arena,
                "another edit in this commit already writes the fragment \"{s}\"; synthesizing here would overwrite it",
                .{f},
            );
        }
        return null;
    }
};

/// Pre-write bytes of one source path a routed edit will rewrite. `content` is
/// null when the path did not exist yet (a synthesized fragment), and
/// `created_dir` is the topmost directory the write has to create for it, so a
/// rollback can also remove the region directories the synthesis created.
const Backup = struct {
    path: []const u8,
    content: ?[]const u8,
    created_dir: ?[]const u8,
};

/// Result of classifying one shared-origin hunk.
const Decision = union(enum) {
    /// Keep the edit at its origin. Payload: labels of the configurations the
    /// edit changes (allowed to differ from their prior compose in
    /// verification).
    origin: []const []const u8,
    /// Narrow the edit to an axis via region synthesis.
    synth: SynthDecision,
    /// Report-only: the analysis was printed; nothing to write.
    report,
    /// User explicitly skipped this hunk at the candidate prompt (`s`): a
    /// deliberate decline, ordinary as declining at the plain `[Y/n/m]`
    /// prompt.
    skip,
    /// The candidate the user picked has no automatic route (private layer,
    /// an unknown comment marker, or a hazard that would corrupt or collide
    /// with another region/fragment). Unlike `skip`, this is not what the
    /// user asked for -- the tool could not honor the choice.
    unroutable,
    /// Hunk downgraded to manual.
    manual,
    abort,
    abort_strict,
};

/// Per-hunk routing prompt choices; index 0 (yes) is the default and index 2
/// (manual) downgrades the hunk. `q` aborts, handled by the prompt module.
const ynm_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes" },
    .{ .key = "n", .label = "no" },
    .{ .key = "m", .label = "manual" },
};

/// F-coupling prompt: `y` updates the other consumer, `d` declines this
/// (token, file-pair), `D` declines the token everywhere.
const yndd_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes" },
    .{ .key = "n", .label = "no" },
    .{ .key = "d", .label = "decline pair" },
    .{ .key = "D", .label = "decline globally" },
};

/// A pending update to a coupled source file: replace `old` with `new`.
const CouplingEdit = struct {
    path: []const u8,
    old: []const u8,
    new: []const u8,
};

/// A single token that a routed edit renamed (old -> new).
const Rename = struct {
    old: []const u8,
    new: []const u8,
};

const Spec = struct {
    dry_run: cli.spec.Flag(.{ .help = "report only, exit 1 if edits remain" }),
    yes: cli.spec.Flag(.{ .help = "take defaults without prompting" }),
    abort_on_prompt: cli.spec.Flag(.{ .help = "strict CI: rc 2 on the first prompt" }),
    paths: cli.spec.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

/// A file's own configuration space, built once from its source and reused
/// across every hunk classification and verification step for that file.
const FileSpace = struct {
    ax: mox.source.axes.Axes,
    configs: []const Configuration,
};

/// Configuration space for `file`: the axes ITS OWN directives express,
/// simulated against this machine's bindings. Building this from the file
/// itself (never a published census) is the whole point of this module: the
/// source is never stale, so every configuration it can express is covered.
fn fileSpace(
    arena: std.mem.Allocator,
    io: Io,
    this_bindings: *const std.StringHashMap([]const u8),
    file: mox.source.tree.ManagedFile,
) !FileSpace {
    const ax = try mox.source.axes.ofFile(arena, io, file);
    const configs = try config_space.enumerate(arena, this_bindings, ax);
    return .{ .ax = ax, .configs = configs };
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const dry_run = a.dry_run;
    const yes = a.yes;

    const lk = (try lock_mod.acquireForCommand(ctx, "commit")) orelse return 1;
    defer lk.release();

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox commit: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    // A scoped commit routes only the named files: everything else is left
    // for a later `mox commit`, so `scoped_live` gates the main routing loop
    // rather than shrinking `tree.files` (which every fidx-indexed array
    // below is still sized against).
    var scoped_live: ?std.StringHashMap(void) = null;
    if (a.paths.len > 0) {
        var diag: scope.Diag = .{};
        const scoped_files = scope.filterTree(ctx.alloc, ctx.io, tree.files, m_state.home, a.paths, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox commit: {s}: not managed\n", .{diag.capture().?});
                return 1;
            },
            else => return e,
        };
        var set: std.StringHashMap(void) = .init(ctx.alloc);
        for (scoped_files) |f| try set.put(f.live_path, {});
        scoped_live = set;
    }

    const scripted_input = app.stdin_override;
    // Strict CI: rc 2 for a prompt that WOULD have been needed. That is a fact
    // about the hunks, not about the terminal, so strict mode walks the
    // prompting path off a TTY too (`prompt.ask` aborts there instead of
    // reading) rather than short-circuiting into the report. `--dry-run` asks
    // nothing at all, so it stays a pure report.
    const strict = a.abort_on_prompt and !dry_run;
    const interactive = ((scripted_input != null or tty.isInteractive(0)) and !dry_run and !yes) or strict;
    const report_mode = dry_run or (!interactive and !yes);
    // `--yes` takes every default without reading input.
    const ask_mode: prompt.Mode = if (a.abort_on_prompt)
        .abort_on_prompt
    else if (yes)
        .assume_default
    else
        .interactive;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: *Io.Reader = scripted_input orelse &stdin_reader.interface;

    var claims: Claims = .empty;

    const cc: ClassCtx = .{
        .arena = ctx.alloc,
        .io = ctx.io,
        .this_bindings = &bindings,
        .m_state = &m_state,
        .secrets = secrets,
        .hostname = m_state.hostname,
        .stdout = ctx.out,
        .input = input,
        .ask_mode = ask_mode,
        .report_mode = report_mode,
        .claims = &claims,
    };

    var line_edits: std.ArrayList(LineEdit) = .empty;
    var row_edits: std.ArrayList(RowEdit) = .empty;
    var synth_plans: std.ArrayList(SynthDecision) = .empty;
    // Index of the managed file each pending edit was routed from, so a file
    // whose routing verification fails can restore exactly the sources it wrote.
    var line_owners: std.ArrayList(usize) = .empty;
    var row_owners: std.ArrayList(usize) = .empty;
    var synth_owners: std.ArrayList(usize) = .empty;
    const affected = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(affected, false);
    // Per-file set of configuration labels the user chose to affect;
    // verification lets exactly these compose differently after the write.
    const allowed = try ctx.alloc.alloc(std.StringHashMap(void), tree.files.len);
    for (allowed) |*s| s.* = std.StringHashMap(void).init(ctx.alloc);
    // Per-file configuration space, built once (when first needed) and
    // reused for that file's own classification and verification.
    const spaces = try ctx.alloc.alloc(?FileSpace, tree.files.len);
    @memset(spaces, null);

    // Per-file tallies of the hunks that did NOT reach a source, which is what
    // tells an EXPECTED recompose mismatch from a broken routing. A manual hunk
    // is a designed outcome (a secret, an interpolation, a structural merge);
    // `declined_hunks` counts hunks the user deliberately left out this run (`n`
    // at the plain prompt, `s` at the candidate prompt) -- an equally ordinary,
    // designed outcome. A file with either cannot recompose to live no matter
    // how well its other hunks routed, and that is expected. `unrouted_hunks`
    // counts hunks the TOOL could not route to the candidate the user picked (no
    // automatic path, a hazard) -- not something the user asked for, so it does
    // NOT explain a mismatch away. The diagnostics name whichever caused it.
    const manual_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(manual_hunks, 0);
    const declined_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(declined_hunks, 0);
    const unrouted_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(unrouted_hunks, 0);

    var pending = false;
    var manual_count: usize = 0;
    var routed_count: usize = 0;
    var skipped_secret: usize = 0;
    var aborted = false;
    var strict_abort = false;

    files: for (tree.files, 0..) |file, fidx| {
        if (scoped_live) |set| {
            if (!set.contains(file.live_path)) continue;
        }
        if (file.is_symlink) continue;
        // Seed-once files carry no applied record and are user-owned after
        // creation; there is nothing to route back to their source.
        if (file.create_once) continue;

        const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
        if (recorded == null) continue;
        const live = Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        const last_content = (try mox.apply.applied.readContent(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path)) orelse {
            // A secret-bearing file's cleartext is deliberately never cached, so
            // an edit to it cannot be routed. Say so when the live file has
            // actually drifted, rather than dropping the edit without a word.
            if (!std.mem.eql(u8, &recorded.?, &mox.apply.applied.contentHashHex(live))) {
                try ctx.out.print("  skipped {s} (contains a secret; edit its source directly)\n", .{file.live_path});
                skipped_secret += 1;
                pending = true;
            }
            continue;
        };
        // Only true drift (live != last-applied) is committable.
        if (std.mem.eql(u8, live, last_content)) continue;

        const prov = (try mox.provenance.map.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path)) orelse {
            try ctx.out.print("  manual: {s} (no provenance recorded)\n", .{file.live_path});
            manual_count += 1;
            manual_hunks[fidx] += 1;
            pending = true;
            continue;
        };

        const a_lines = try mox.diff.lines.splitLines(ctx.alloc, last_content);
        const b_lines = try mox.diff.lines.splitLines(ctx.alloc, live);
        const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
            error.TooManyLines => {
                try ctx.out.print("  manual: {s} (too large to diff)\n", .{file.live_path});
                manual_count += 1;
                manual_hunks[fidx] += 1;
                pending = true;
                continue;
            },
            else => return e,
        };

        // Built once per file (from ITS OWN source, never a published
        // census) and reused across every hunk below.
        if (spaces[fidx] == null) spaces[fidx] = try fileSpace(ctx.alloc, ctx.io, &bindings, file);
        const space = spaces[fidx].?;

        for (hunks) |hunk| {
            const route = try routeHunk(ctx.alloc, ctx.io, prov.segments, hunk, file, a_lines, b_lines);
            switch (route) {
                .manual => |reason| {
                    manual_count += 1;
                    manual_hunks[fidx] += 1;
                    pending = true;
                    try ctx.out.print("  manual: {s}:{d} {s}\n", .{ file.live_path, hunk.a_start + 1, reason });
                },
                .line => |r| {
                    routed_count += 1;
                    // A shared-origin edit in a file whose OWN configuration
                    // space has more than one member asks where the edit
                    // belongs; everything else keeps the origin behind a plain
                    // [Y/n/m] confirm (bootstrap / axis-specific / private).
                    if (r.shared and space.configs.len > 1) {
                        switch (try classifyLine(&cc, file, r.edit, r.desc, space)) {
                            .abort => {
                                aborted = true;
                                break :files;
                            },
                            .abort_strict => {
                                strict_abort = true;
                                break :files;
                            },
                            .report => {
                                pending = true;
                                // Report mode returns before the write phase;
                                // the edit is collected only so the coupling
                                // updates a real commit would offer are also
                                // surfaced.
                                try line_edits.append(ctx.alloc, r.edit);
                                try line_owners.append(ctx.alloc, fidx);
                            },
                            .skip => declined_hunks[fidx] += 1,
                            .unroutable => unrouted_hunks[fidx] += 1,
                            .manual => {
                                manual_count += 1;
                                manual_hunks[fidx] += 1;
                                pending = true;
                            },
                            .origin => |labels| {
                                try line_edits.append(ctx.alloc, r.edit);
                                try line_owners.append(ctx.alloc, fidx);
                                affected[fidx] = true;
                                for (labels) |l| try allowed[fidx].put(l, {});
                                try ctx.out.print("  edit {s}\n", .{r.desc});
                            },
                            .synth => |sd| {
                                try synth_plans.append(ctx.alloc, sd);
                                try synth_owners.append(ctx.alloc, fidx);
                                affected[fidx] = true;
                                for (sd.allowed) |l| try allowed[fidx].put(l, {});
                                // Preview the synthesized directive structure
                                // before any write.
                                try ctx.out.print("  synthesize {s}={s} region in {s}\n", .{ sd.plan.region, sd.plan.value, r.desc });
                                try ctx.out.print("    + {s}\n", .{sd.plan.directive_line});
                                try ctx.out.print("    + fragment {s}\n", .{sd.plan.fragment_path});
                            },
                        }
                        continue;
                    }

                    var accept = !report_mode and !interactive;
                    if (report_mode) {
                        pending = true;
                        try ctx.out.print("  would edit {s}\n", .{r.desc});
                        try printMiniDiff(ctx.out, hunk, a_lines, b_lines);
                        // Collected so report mode can also surface coupling
                        // divergences; never written (report mode returns
                        // before the write phase).
                        try line_edits.append(ctx.alloc, r.edit);
                        try line_owners.append(ctx.alloc, fidx);
                    } else if (interactive) {
                        try ctx.out.print("  edit {s}\n", .{r.desc});
                        try printMiniDiff(ctx.out, hunk, a_lines, b_lines);
                        switch (try prompt.ask(ask_mode, &ynm_choices, 0, "  [Y/n/m/q] ", input, ctx.out)) {
                            .chosen => |i| switch (i) {
                                0 => accept = true,
                                1 => declined_hunks[fidx] += 1,
                                else => {
                                    manual_count += 1;
                                    manual_hunks[fidx] += 1;
                                },
                            },
                            .abort => {
                                aborted = true;
                                break :files;
                            },
                            .abort_strict => {
                                strict_abort = true;
                                break :files;
                            },
                            .report_only => unreachable,
                        }
                    }
                    if (accept) {
                        try line_edits.append(ctx.alloc, r.edit);
                        try line_owners.append(ctx.alloc, fidx);
                        affected[fidx] = true;
                        // This route made no classification choice (axis-gated
                        // fragment, private layer, or a file with a single
                        // configuration): the configurations its origin feeds
                        // are exactly the ones it is meant to change, so
                        // verification must expect them to differ.
                        if (space.configs.len > 1) {
                            const imp = try simulateImpact(&cc, file, r.edit, space.configs);
                            for (imp.affected) |l| try allowed[fidx].put(l, {});
                        }
                        if (!interactive and !report_mode)
                            try ctx.out.print("  edit {s}\n", .{r.desc});
                    }
                },
                .row => |r| {
                    routed_count += 1;
                    var accept = !report_mode and !interactive;
                    if (report_mode) {
                        pending = true;
                        try ctx.out.print("  would update {s}\n", .{r.desc});
                        try printMiniDiff(ctx.out, hunk, a_lines, b_lines);
                    } else if (interactive) {
                        try ctx.out.print("  update {s}\n", .{r.desc});
                        try printMiniDiff(ctx.out, hunk, a_lines, b_lines);
                        switch (try prompt.ask(ask_mode, &ynm_choices, 0, "  [Y/n/m/q] ", input, ctx.out)) {
                            .chosen => |i| switch (i) {
                                0 => accept = true,
                                1 => declined_hunks[fidx] += 1,
                                else => {
                                    manual_count += 1;
                                    manual_hunks[fidx] += 1;
                                },
                            },
                            .abort => {
                                aborted = true;
                                break :files;
                            },
                            .abort_strict => {
                                strict_abort = true;
                                break :files;
                            },
                            .report_only => unreachable,
                        }
                    }
                    if (accept) {
                        try row_edits.append(ctx.alloc, r.edit);
                        try row_owners.append(ctx.alloc, fidx);
                        affected[fidx] = true;
                        // A loop row belongs to its data source, not to any
                        // configuration: like the non-shared line routes above,
                        // it makes no classification choice, so the
                        // configurations it feeds are the ones it may change.
                        if (space.configs.len > 1) {
                            const imp = try simulateRowImpact(&cc, file, r.edit, space.configs);
                            for (imp.affected) |l| try allowed[fidx].put(l, {});
                        }
                        if (!interactive and !report_mode)
                            try ctx.out.print("  update {s}\n", .{r.desc});
                    }
                },
            }
        }
    }

    if (strict_abort) {
        try ctx.err.writeAll("mox commit: --abort-on-prompt: a prompt was required; nothing written\n");
        return 2;
    }
    if (aborted) {
        try ctx.out.writeAll("mox commit: aborted; no changes written\n");
        return 1;
    }

    const coupling_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "coupling" });
    const protected = try protectedSourceSet(ctx.alloc, tree.files);

    if (report_mode) {
        // Report the coupling updates a real commit would offer for the routed
        // renames, honoring declines. Nothing is written; each pending update
        // counts toward the "edits remain" exit code. A path-scoped commit
        // routes only the named files and must not reach out to other sources.
        const coupled = if (scoped_live == null and line_edits.items.len > 0)
            try reportCoupling(ctx.alloc, ctx.io, coupling_dir, line_edits.items, &protected, ctx.out)
        else
            0;
        if (coupled > 0) pending = true;
        if (routed_count == 0 and manual_count == 0 and coupled == 0 and skipped_secret == 0) {
            try ctx.out.writeAll("mox commit: nothing to commit\n");
        } else if (skipped_secret > 0) {
            try ctx.out.print(
                "\nmox commit: {d} routable, {d} coupled, {d} manual, {d} skipped (report only; run without --dry-run on a terminal to apply)\n",
                .{ routed_count, coupled, manual_count, skipped_secret },
            );
        } else {
            try ctx.out.print(
                "\nmox commit: {d} routable, {d} coupled, {d} manual (report only; run without --dry-run on a terminal to apply)\n",
                .{ routed_count, coupled, manual_count },
            );
        }
        return if (pending) 1 else 0;
    }

    // F-coupling: a token a routed edit changed may live in other managed
    // sources; offer to update them in the same write pass. Runs after routing
    // (final edits known) and before any write (abort still writes nothing). A
    // path-scoped commit routes only the named files and must not reach out to
    // couple other sources, so the whole pass is skipped when scoped.
    var coupling_edits: []const CouplingEdit = &.{};
    if (scoped_live == null and line_edits.items.len > 0) {
        const cres = try resolveCoupling(ctx.alloc, ctx.io, coupling_dir, line_edits.items, &protected, ask_mode, input, ctx.out);
        if (cres.abort) aborted = true;
        if (cres.abort_strict) strict_abort = true;
        // A q-abort (or strict-mode prompt) must persist nothing: the decline
        // list is saved only when the command did not abort.
        if (cres.save_declines) try mox.coupling.store.saveDeclines(ctx.alloc, ctx.io, coupling_dir, &cres.declines);
        // A symlink target string or a seed-once body must never be rewritten by
        // a coupling sync: symlinks and seed files are user-owned after creation
        // and are never edit sources, so a token they happen to share must not be
        // synced into them. The coupling graph may still index them, so drop any
        // edit that lands on one before the write pass (mirrors the direct
        // routing loop's is_symlink/create_once skips).
        coupling_edits = try dropProtectedCouplingEdits(ctx.alloc, cres.edits, tree.files);
    }

    if (strict_abort) {
        try ctx.err.writeAll("mox commit: --abort-on-prompt: a prompt was required; nothing written\n");
        return 2;
    }
    if (aborted) {
        try ctx.out.writeAll("mox commit: aborted; no changes written\n");
        return 1;
    }

    // Coupling edits touch OTHER managed sources whose live files the user did
    // not edit. They must be verified like routed edits (design section 5 step
    // 3: recompose-verify over EVERY touched file), but with two differences:
    // their recompose need not equal live (apply refreshes it), and a failure
    // restores the source rather than leaving it edited. Mark each such file,
    // snapshot its bytes for rollback, and record which configurations a
    // universal token sync may change so a subset divergence is caught.
    const coupling_only = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(coupling_only, false);
    const coupling_orig = try ctx.alloc.alloc(?[]const u8, tree.files.len);
    @memset(coupling_orig, null);
    for (tree.files, 0..) |file, fidx| {
        if (affected[fidx]) continue;
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        const file_edits = try couplingEditsForPath(ctx.alloc, coupling_edits, file.source_base_abs);
        if (file_edits.len == 0) continue;
        coupling_only[fidx] = true;
        coupling_orig[fidx] = try Io.Dir.cwd().readFileAlloc(ctx.io, file.source_base_abs, ctx.alloc, .limited(max_file_bytes));
        if (spaces[fidx] == null) spaces[fidx] = try fileSpace(ctx.alloc, ctx.io, &bindings, file);
        const space = spaces[fidx].?;
        // A token sync is legitimate only when universal: if it changes
        // every sibling configuration, allow them all; a strict subset stays
        // disallowed so verification aborts it.
        if (space.configs.len > 1) {
            const imp = try simulateCouplingImpact(&cc, file, file.source_base_abs, file_edits, space.configs);
            const n_other = space.configs.len - 1;
            if (imp.affected.len >= n_other) {
                for (imp.affected) |label| try allowed[fidx].put(label, {});
            }
        }
    }

    // Pre-write bytes of every source a routed edit will rewrite, grouped by
    // the file it was routed from. When verification rejects that file's
    // routing, these restore its sources exactly -- "not committed" must leave
    // nothing behind, including a fragment the synthesis created.
    const routed_orig = try ctx.alloc.alloc([]const Backup, tree.files.len);
    @memset(routed_orig, &.{});
    for (tree.files, 0..) |_, fidx| {
        if (!affected[fidx]) continue;
        var bs: std.ArrayList(Backup) = .empty;
        for (line_edits.items, line_owners.items) |e, owner| {
            if (owner == fidx) try addBackup(ctx.alloc, ctx.io, &bs, e.path);
        }
        for (row_edits.items, row_owners.items) |e, owner| {
            if (owner == fidx) try addBackup(ctx.alloc, ctx.io, &bs, e.data_source);
        }
        for (synth_plans.items, synth_owners.items) |sd, owner| {
            if (owner != fidx) continue;
            try addBackup(ctx.alloc, ctx.io, &bs, sd.base_abs);
            try addBackup(ctx.alloc, ctx.io, &bs, sd.plan.fragment_path);
        }
        routed_orig[fidx] = try bs.toOwnedSlice(ctx.alloc);
    }

    // Baseline: each touched file's per-configuration compose BEFORE writing,
    // so verification can prove routing changed only the configurations the
    // user chose. Each file's configuration space was built once, from its
    // own source, when it was first classified above.
    const baseline = try ctx.alloc.alloc([]const ?[]const u8, tree.files.len);
    for (tree.files, 0..) |file, fidx| {
        if (!affected[fidx] and !coupling_only[fidx]) continue;
        const space = spaces[fidx].?;
        baseline[fidx] = (try impact.snapshot(ctx.alloc, ctx.io, file, space.configs, &m_state, secrets)).per_config;
    }

    // Write phase: every prompt is done, so applying now honors the
    // abort-writes-nothing contract.
    //
    // A narrowing's region block is a line SPLICE of the base like any other
    // edit, so a base with narrowings is written once, from its CURRENT bytes,
    // with its ordinary line edits and every region block spliced in together.
    // A universal hunk and a narrowed hunk in one file therefore both land, and
    // neither reverts the other.
    const synth_bases = try synthBases(ctx.alloc, synth_plans.items);
    try applyLineEdits(ctx.alloc, ctx.io, try lineEditsExcluding(ctx.alloc, line_edits.items, synth_bases));
    try applyRowEdits(ctx.alloc, ctx.io, row_edits.items);
    for (synth_bases) |base_abs| {
        var splices: std.ArrayList(LineEdit) = .empty;
        for (line_edits.items) |e| {
            if (std.mem.eql(u8, e.path, base_abs)) try splices.append(ctx.alloc, e);
        }
        var plans: std.ArrayList(mox.classify.synth.Plan) = .empty;
        for (synth_plans.items) |sd| {
            if (!std.mem.eql(u8, sd.base_abs, base_abs)) continue;
            try plans.append(ctx.alloc, sd.plan);
            try splices.append(ctx.alloc, .{
                .path = base_abs,
                .start = sd.plan.start,
                .del = sd.plan.del,
                .new_lines = sd.plan.base_lines,
            });
        }
        const base_content = try splicedContent(ctx.alloc, ctx.io, base_abs, splices.items);
        try mox.classify.synth.materialize(ctx.alloc, ctx.io, base_abs, base_content, plans.items);
    }
    try applyCouplingEdits(ctx.alloc, ctx.io, coupling_edits);

    // Rewalk so region synthesis (new fragments/regions) is reflected when the
    // edited files are recomposed and verified.
    const base_tree2 = try mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home);
    const tree2 = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree2, context.paths.private_dir, m_state.home);

    var mismatch = false;
    var committed_count: usize = 0;
    // A file whose sources were put back: what it wrote is gone, so neither it
    // nor any coupled update to it counts as committed.
    const rolled_back = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(rolled_back, false);
    for (tree.files, 0..) |file, fidx| {
        const is_routed = affected[fidx];
        const is_coupling = coupling_only[fidx];
        if (!is_routed and !is_coupling) continue;
        const configs = spaces[fidx].?.configs;
        const file2 = findByLive(tree2, file.live_path) orelse file;
        var prov2: std.ArrayList(Segment) = .empty;
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file2, &bindings, &m_state, secrets, &prov2, null) catch |e| {
            try ctx.err.print("mox commit: {s}: recompose failed; not committed: {s}\n", .{ file.live_path, @errorName(e) });
            mismatch = true;
            rolled_back[fidx] = true;
            if (is_coupling) {
                try restoreCouplingTarget(ctx.io, file.source_base_abs, coupling_orig[fidx]);
            } else {
                try restoreRouted(ctx.io, routed_orig[fidx]);
            }
            continue;
        };

        if (is_coupling) {
            // The live file was not user-edited, so recompose need not equal
            // live; verify only that the source still composes and that the
            // sync does not diverge a configuration the user did not choose.
            if (composed == null) {
                try ctx.err.print("mox commit: {s}: coupled update made the source uncomposable; not committed\n", .{file.source_base_abs});
                mismatch = true;
                rolled_back[fidx] = true;
                try restoreCouplingTarget(ctx.io, file.source_base_abs, coupling_orig[fidx]);
                continue;
            }
            const after_per = (try impact.snapshot(ctx.alloc, ctx.io, file2, configs, &m_state, secrets)).per_config;
            if (candidates.firstViolation(configs, baseline[fidx], after_per, &allowed[fidx])) |vi| {
                try ctx.err.print(
                    "mox commit: {s}: coupled token update would change configuration {s}, which you did not choose to affect; not committed\n",
                    .{ file.source_base_abs, configs[vi].label },
                );
                mismatch = true;
                rolled_back[fidx] = true;
                try restoreCouplingTarget(ctx.io, file.source_base_abs, coupling_orig[fidx]);
                continue;
            }
            // Synced safely; the applied record advances at the next apply.
            continue;
        }

        const live = Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(max_file_bytes)) catch "";
        // The routing made the source uncomposable: nothing about the edit can
        // explain that, so it is a bug in the write. Put every source back.
        if (composed == null) {
            mismatch = true;
            rolled_back[fidx] = true;
            try restoreRouted(ctx.io, routed_orig[fidx]);
            try ctx.err.print(
                "mox commit: {s}: the edited sources no longer compose; not committed\n",
                .{file.live_path},
            );
            continue;
        }
        if (!std.mem.eql(u8, composed.?, live)) {
            mismatch = true;
            // A manual hunk and a hunk the user deliberately declined (`n`) or
            // skipped (`s`) are both DESIGNED outcomes -- the first has no safe
            // route at all, the second is the user choosing not to commit it
            // this run -- and either stays only in the live file, so the
            // recompose is EXPECTED to still differ. Rolling the file back for
            // that would make the most ordinary mixed edit (one hunk committed,
            // one left alone) uncommittable forever. The routed hunks stand;
            // the applied record does not advance, so the rest still shows as
            // drift.
            const explained = manual_hunks[fidx] + declined_hunks[fidx];
            if (explained > 0) {
                if (manual_hunks[fidx] > 0 and declined_hunks[fidx] > 0) {
                    try ctx.err.print(
                        "mox commit: {s}: {d} hunk(s) could not be routed and {d} hunk(s) were declined; both remain only " ++
                            "in the live file; the routed edits were committed to the sources -- edit the rest in by hand, " ++
                            "then run 'mox apply'\n",
                        .{ file.live_path, manual_hunks[fidx], declined_hunks[fidx] },
                    );
                } else if (manual_hunks[fidx] > 0) {
                    try ctx.err.print(
                        "mox commit: {s}: {d} hunk(s) could not be routed and remain only in the live file; " ++
                            "the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n",
                        .{ file.live_path, manual_hunks[fidx] },
                    );
                } else {
                    try ctx.err.print(
                        "mox commit: {s}: {d} hunk(s) were declined and remain only in the live file; " ++
                            "the routed edits were committed to the sources -- run 'mox apply' to discard them\n",
                        .{ file.live_path, declined_hunks[fidx] },
                    );
                }
                try ctx.out.print("  committed {s}\n", .{file.live_path});
                committed_count += 1;
                continue;
            }
            // Nothing explains the difference away: either a narrowing the tool
            // could not honor is missing from the sources, or the routing
            // itself is wrong. Either way this file is not committed, and "not
            // committed" leaves nothing behind.
            rolled_back[fidx] = true;
            try restoreRouted(ctx.io, routed_orig[fidx]);
            if (unrouted_hunks[fidx] > 0) {
                try ctx.err.print(
                    "mox commit: {s}: {d} hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n",
                    .{ file.live_path, unrouted_hunks[fidx] },
                );
            } else {
                try ctx.err.print(
                    "mox commit: {s}: recomposed output still differs from live; not committed\n",
                    .{file.live_path},
                );
            }
            continue;
        }
        // No classification choice may silently change another configuration:
        // every sibling must recompose to its prior output unless allowed.
        const after_per = (try impact.snapshot(ctx.alloc, ctx.io, file2, configs, &m_state, secrets)).per_config;
        if (candidates.firstViolation(configs, baseline[fidx], after_per, &allowed[fidx])) |vi| {
            mismatch = true;
            rolled_back[fidx] = true;
            try restoreRouted(ctx.io, routed_orig[fidx]);
            try ctx.err.print(
                "mox commit: {s}: routing would change configuration {s}, which you did not choose to affect; not committed\n",
                .{ file.live_path, configs[vi].label },
            );
            continue;
        }
        try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, live);
        // Never cache the cleartext of a secret-bearing composition.
        if (!mox.provenance.map.hasSecret(prov2.items)) {
            try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, live);
        }
        try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, prov2.items);
        try ctx.out.print("  committed {s}\n", .{file.live_path});
        committed_count += 1;
    }

    // Re-index the coupling graph from the post-write sources so a later
    // commit sees the current token layout.
    mox.coupling.store.saveGraph(ctx.alloc, ctx.io, coupling_dir, &(try buildCouplingGraph(ctx.alloc, ctx.io, tree2))) catch {};

    // The counts are what SURVIVED verification, never what was attempted: a
    // rejected file was rolled back, so nothing of it -- neither its own routing
    // nor a coupled update to its source -- was committed.
    var coupled_count: usize = 0;
    for (coupling_edits) |ce| {
        if (!targetRolledBack(tree, rolled_back, ce.path)) coupled_count += 1;
    }
    if (skipped_secret > 0) {
        try ctx.out.print(
            "\nmox commit: {d} committed, {d} coupled, {d} manual, {d} skipped\n",
            .{ committed_count, coupled_count, manual_count, skipped_secret },
        );
    } else {
        try ctx.out.print(
            "\nmox commit: {d} committed, {d} coupled, {d} manual\n",
            .{ committed_count, coupled_count, manual_count },
        );
    }
    return if (mismatch or skipped_secret > 0) 1 else 0;
}

/// True when `path` is the base source of a file whose write was rolled back,
/// so a coupled update written into it is gone again.
fn targetRolledBack(tree: mox.source.tree.ManagedTree, rolled_back: []const bool, path: []const u8) bool {
    for (tree.files, 0..) |f, i| {
        if (!f.has_base or f.source_base_abs.len == 0) continue;
        if (std.mem.eql(u8, f.source_base_abs, path)) return rolled_back[i];
    }
    return false;
}

/// Outcome of F-coupling resolution over the routed edits.
const CouplingOutcome = struct {
    /// Updates to apply to other managed sources in the write pass.
    edits: []const CouplingEdit,
    /// The (possibly amended) decline list.
    declines: mox.coupling.decline.DeclineList,
    /// True only when a decline was recorded AND the command did not abort. A
    /// `q`-abort must persist nothing -- including declines -- so this is false
    /// whenever `abort`/`abort_strict` is set.
    save_declines: bool,
    abort: bool = false,
    abort_strict: bool = false,
};

/// For each routed rename, find other managed sources still holding the old
/// token and prompt to update them. Runs after routing and before any write, so
/// an abort here writes nothing: on `q` (or a strict-mode prompt) no coupling
/// edit is applied and no decline is persisted (`save_declines` stays false).
fn resolveCoupling(
    arena: std.mem.Allocator,
    io: Io,
    coupling_dir: []const u8,
    line_edits: []const LineEdit,
    protected: *const std.StringHashMap(void),
    ask_mode: prompt.Mode,
    input: *Io.Reader,
    stdout: *Io.Writer,
) !CouplingOutcome {
    var edits: std.ArrayList(CouplingEdit) = .empty;
    var graph = try mox.coupling.store.loadGraph(arena, io, coupling_dir);
    var declines = try mox.coupling.store.loadDeclines(arena, io, coupling_dir);
    var declines_changed = false;
    var aborted = false;
    var strict = false;

    coupling: for (line_edits) |e| {
        // A private-layer edit must never sync a token into the shared repo:
        // the graph is rebuilt over the merged tree and does index private-only
        // files, so `e.private` (set from the edit's source LOCATION, not its
        // provenance tag) is what keeps a private rename out of shared sources.
        if (e.private) continue;
        const rename = (try detectRename(arena, io, e)) orelse continue;
        const occs = graph.lookup(rename.old) orelse continue;
        var seen = std.StringHashMap(void).init(arena);
        for (occs) |o| {
            if (std.mem.eql(u8, o.file_id, e.path)) continue;
            // A symlink target / seed-once body is never token-synced, so it is
            // never prompted, announced, or counted here (its write is filtered
            // out separately as a safety net for a stale graph).
            if (protected.contains(o.file_id)) continue;
            if ((try seen.getOrPut(o.file_id)).found_existing) continue;
            if (declines.isPairDeclined(rename.old, e.path, o.file_id)) continue;
            const content = Io.Dir.cwd().readFileAlloc(io, o.file_id, arena, .limited(max_file_bytes)) catch continue;
            if (std.mem.indexOf(u8, content, rename.old) == null) continue;

            const q = try std.fmt.allocPrint(arena, "  \"{s}\" -> \"{s}\": also in {s}. Update? [Y/n/d/D/q] ", .{ rename.old, rename.new, o.file_id });
            switch (try prompt.ask(ask_mode, &yndd_choices, 0, q, input, stdout)) {
                .chosen => |i| switch (i) {
                    0 => {
                        try edits.append(arena, .{ .path = o.file_id, .old = rename.old, .new = rename.new });
                        try stdout.print("  update {s}: \"{s}\" -> \"{s}\"\n", .{ o.file_id, rename.old, rename.new });
                    },
                    1 => {},
                    2 => {
                        try declines.declinePair(rename.old, e.path, o.file_id);
                        declines_changed = true;
                    },
                    else => {
                        try declines.declineGlobal(rename.old);
                        declines_changed = true;
                    },
                },
                .abort => {
                    aborted = true;
                    break :coupling;
                },
                .abort_strict => {
                    strict = true;
                    break :coupling;
                },
                .report_only => {},
            }
        }
    }

    return .{
        .edits = try edits.toOwnedSlice(arena),
        .declines = declines,
        .save_declines = declines_changed and !aborted and !strict,
        .abort = aborted,
        .abort_strict = strict,
    };
}

/// Report-only counterpart of `resolveCoupling`: count and print the coupling
/// updates a real commit would offer for the routed renames, honoring declines.
/// Prompts nothing and writes nothing (report / non-TTY / dry-run mode).
fn reportCoupling(
    arena: std.mem.Allocator,
    io: Io,
    coupling_dir: []const u8,
    line_edits: []const LineEdit,
    protected: *const std.StringHashMap(void),
    stdout: *Io.Writer,
) !usize {
    var graph = try mox.coupling.store.loadGraph(arena, io, coupling_dir);
    var declines = try mox.coupling.store.loadDeclines(arena, io, coupling_dir);
    var count: usize = 0;

    for (line_edits) |e| {
        // Private edits never couple into the shared repo (see resolveCoupling).
        if (e.private) continue;
        const rename = (try detectRename(arena, io, e)) orelse continue;
        const occs = graph.lookup(rename.old) orelse continue;
        var seen = std.StringHashMap(void).init(arena);
        for (occs) |o| {
            if (std.mem.eql(u8, o.file_id, e.path)) continue;
            // A symlink target / seed-once body is never token-synced, so it is
            // never prompted, announced, or counted here (its write is filtered
            // out separately as a safety net for a stale graph).
            if (protected.contains(o.file_id)) continue;
            if ((try seen.getOrPut(o.file_id)).found_existing) continue;
            if (declines.isPairDeclined(rename.old, e.path, o.file_id)) continue;
            const content = Io.Dir.cwd().readFileAlloc(io, o.file_id, arena, .limited(max_file_bytes)) catch continue;
            if (std.mem.indexOf(u8, content, rename.old) == null) continue;
            try stdout.print("  would update {s}: \"{s}\" -> \"{s}\"\n", .{ o.file_id, rename.old, rename.new });
            count += 1;
        }
    }
    return count;
}

/// Detect a single-token rename in a line edit: the token present in the old
/// source lines but gone from the new, paired with the sole newly-introduced
/// token. Returns null unless exactly one token was removed and one added.
fn detectRename(arena: std.mem.Allocator, io: Io, edit: LineEdit) !?Rename {
    const content = Io.Dir.cwd().readFileAlloc(io, edit.path, arena, .limited(max_file_bytes)) catch return null;
    const lines = try mox.diff.lines.splitLines(arena, content);
    const start = @min(edit.start, lines.len);
    const end = @min(start + edit.del, lines.len);
    const old_text = try std.mem.join(arena, "\n", lines[start..end]);
    const new_text = try std.mem.join(arena, "\n", edit.new_lines);

    const old_toks = try mox.coupling.tokens.extract(arena, old_text);
    const new_toks = try mox.coupling.tokens.extract(arena, new_text);

    var removed: ?[]const u8 = null;
    var removed_count: usize = 0;
    for (old_toks) |t| {
        if (!containsToken(new_toks, t)) {
            removed = t;
            removed_count += 1;
        }
    }
    var added: ?[]const u8 = null;
    var added_count: usize = 0;
    for (new_toks) |t| {
        if (!containsToken(old_toks, t)) {
            added = t;
            added_count += 1;
        }
    }
    if (removed_count != 1 or added_count != 1) return null;
    return .{ .old = removed.?, .new = added.? };
}

fn containsToken(toks: []const []const u8, tok: []const u8) bool {
    for (toks) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

/// Apply coupling edits: in each target file, replace every occurrence of the
/// old token with the new one. Grouped so a file is rewritten once.
fn applyCouplingEdits(arena: std.mem.Allocator, io: Io, edits: []const CouplingEdit) !void {
    var done: std.ArrayList([]const u8) = .empty;
    for (edits) |e| {
        var seen = false;
        for (done.items) |p| {
            if (std.mem.eql(u8, p, e.path)) seen = true;
        }
        if (seen) continue;
        try done.append(arena, e.path);

        var content = try Io.Dir.cwd().readFileAlloc(io, e.path, arena, .limited(max_file_bytes));
        for (edits) |fe| {
            if (!std.mem.eql(u8, fe.path, e.path)) continue;
            content = try replaceToken(arena, content, fe.old, fe.new);
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = e.path, .data = content });
    }
}

/// Replace only the occurrences of `old` in `content` that are themselves
/// complete tokens: bounded by a non-token char or a string edge, matching how
/// `coupling/tokens.zig` extracts tokens (a token is a maximal run of token
/// chars). An occurrence embedded in a longer token is left intact, so renaming
/// one token never corrupts a superstring of it. Returns arena-owned bytes.
fn replaceToken(arena: std.mem.Allocator, content: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return arena.dupe(u8, content);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], old)) {
            const before_ok = i == 0 or !mox.coupling.tokens.isTokenChar(content[i - 1]);
            const after = i + old.len;
            const after_ok = after >= content.len or !mox.coupling.tokens.isTokenChar(content[after]);
            if (before_ok and after_ok) {
                try out.appendSlice(arena, new);
                i = after;
                continue;
            }
        }
        try out.append(arena, content[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Drop coupling edits that would rewrite a symlink target or a seed-once
/// source. Those files are user-owned and never edit sources, so a shared token
/// must not be synced into them even when the coupling graph indexes them.
/// Source files that must never receive a coupling token sync: a symlink
/// source's content is a link target, a seed-once source's is a one-time seed.
/// Keyed by absolute source path (the coupling graph's file id).
fn protectedSourceSet(arena: std.mem.Allocator, files: []const mox.source.tree.ManagedFile) !std.StringHashMap(void) {
    var protected = std.StringHashMap(void).init(arena);
    for (files) |f| {
        if ((f.is_symlink or f.create_once) and f.source_base_abs.len > 0) {
            try protected.put(f.source_base_abs, {});
        }
    }
    return protected;
}

fn dropProtectedCouplingEdits(arena: std.mem.Allocator, edits: []const CouplingEdit, files: []const mox.source.tree.ManagedFile) ![]const CouplingEdit {
    var protected = try protectedSourceSet(arena, files);
    if (protected.count() == 0) return edits;
    var out: std.ArrayList(CouplingEdit) = .empty;
    for (edits) |e| {
        if (protected.contains(e.path)) continue;
        try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// Coupling edits targeting `path`, in order. Grouped so a target file's
/// combined token sync can be simulated and applied as a unit.
fn couplingEditsForPath(arena: std.mem.Allocator, edits: []const CouplingEdit, path: []const u8) ![]const CouplingEdit {
    var out: std.ArrayList(CouplingEdit) = .empty;
    for (edits) |e| {
        if (std.mem.eql(u8, e.path, path)) try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// Impact of a coupling target's token sync: snapshot every configuration's
/// compose, transiently apply the token replacements to the source, snapshot
/// again, then restore. The transient write is always reverted.
fn simulateCouplingImpact(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    path: []const u8,
    file_edits: []const CouplingEdit,
    configs: []const Configuration,
) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes));
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    var edited: []const u8 = original;
    for (file_edits) |ce| edited = try replaceToken(arena, edited, ce.old, ce.new);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = edited });
    const after = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original }) catch {};
        return e;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    return impact.impact(arena, configs, before, after);
}

/// Roll a rejected coupling edit back to the source's pre-write bytes.
fn restoreCouplingTarget(io: Io, path: []const u8, original: ?[]const u8) !void {
    const bytes = original orelse return;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Record `path`'s pre-write state once, so a rejected routing can restore it.
fn addBackup(arena: std.mem.Allocator, io: Io, list: *std.ArrayList(Backup), path: []const u8) !void {
    for (list.items) |b| {
        if (std.mem.eql(u8, b.path, path)) return;
    }
    const content: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    try list.append(arena, .{ .path = path, .content = content, .created_dir = mox.classify.synth.missingAncestor(io, path) });
}

/// Roll a rejected routing back to its sources' pre-write bytes: a file that
/// existed regains its exact content, and one the synthesis created is removed
/// -- along with every directory it created to hold it.
fn restoreRouted(io: Io, backups: []const Backup) !void {
    for (backups) |b| {
        if (b.content) |bytes| {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = b.path, .data = bytes });
            continue;
        }
        Io.Dir.cwd().deleteFile(io, b.path) catch {};
        if (b.created_dir) |d| Io.Dir.cwd().deleteTree(io, d) catch {};
    }
}

/// Build a coupling graph over the tree's base source files, keyed by absolute
/// source path so commit can resolve postings to files it can rewrite.
fn buildCouplingGraph(arena: std.mem.Allocator, io: Io, tree: mox.source.tree.ManagedTree) !mox.coupling.graph.Graph {
    var inputs: std.ArrayList(mox.coupling.index.FileInput) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        // A symlink target / seed-once body is never token-synced, so keep it
        // out of the coupling graph entirely (matches add/doctor builders).
        if (file.is_symlink or file.create_once) continue;
        const content = Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes)) catch continue;
        try inputs.append(arena, .{ .id = file.source_base_abs, .content = content });
    }
    return mox.coupling.index.build(arena, inputs.items);
}

/// Map one diff hunk to a source edit, or report why it cannot be routed.
fn routeHunk(
    arena: std.mem.Allocator,
    io: Io,
    segments: []const Segment,
    hunk: Hunk,
    file: mox.source.tree.ManagedFile,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) !Route {
    const seg = mox.provenance.map.covering(segments, hunk.a_start, hunk.a_len) orelse
        return .{ .manual = "hunk straddles origins or is uncovered" };
    const new_lines = b_lines[hunk.b_start .. hunk.b_start + hunk.b_len];
    const old_lines = a_lines[hunk.a_start .. hunk.a_start + hunk.a_len];

    switch (seg.origin) {
        .base => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceLinesMatch(arena, io, file.source_base_abs, start, old_lines))
                return .{ .manual = "source no longer matches recorded provenance" };
            return lineRoute(arena, file.source_base_abs, file.source_base_path, start, hunk.a_len, new_lines, true, isUnderPrivate(file.source_base_abs, file.private_dir));
        },
        .fragment => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceLinesMatch(arena, io, o.path, start, old_lines))
                return .{ .manual = "source no longer matches recorded provenance" };
            // A region fragment is already axis-gated; an include/append/prepend
            // fragment is universal, so its edit is shared and gets classified.
            return lineRoute(arena, o.path, o.path, start, hunk.a_len, new_lines, !isRegionFragment(file, o.path), isUnderPrivate(o.path, file.private_dir));
        },
        .private => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceLinesMatch(arena, io, o.path, start, old_lines))
                return .{ .manual = "source no longer matches recorded provenance" };
            return lineRoute(arena, o.path, o.path, start, hunk.a_len, new_lines, false, true);
        },
        .loop => |o| {
            if (std.mem.indexOfScalar(u8, o.template, '\n') != null)
                return .{ .manual = "multi-line loop template" };
            if (hunk.a_len != 1 or hunk.b_len != 1)
                return .{ .manual = "loop row insertion or deletion" };
            const row = o.row + (hunk.a_start - seg.out_start);
            const fields = reverseTemplate(arena, o.template, new_lines[0]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            } orelse return .{ .manual = "live line does not match loop template" };
            const stem = try arena.dupe(u8, filenameStem(o.data_source));
            const desc = try std.fmt.allocPrint(arena, "{s} row {d}", .{ o.data_source, row });
            return .{ .row = .{
                .edit = .{ .data_source = o.data_source, .stem = stem, .row = row, .fields = fields },
                .desc = desc,
            } };
        },
        .secret => return .{ .manual = "came from a secret" },
        .interpolated => return .{ .manual = "came from a capture" },
        .overlay => return .{ .manual = "came from a structural merge" },
    }
}

/// Confirm the source file at `path` still holds `expected` verbatim at line
/// index `start` (0-based). Guards the 1:1 assumption behind offset routing:
/// a fragment line rewritten by `<machine.X>` interpolation, or any residual
/// provenance mis-mapping, fails this check so the hunk downgrades to manual
/// rather than silently overwriting the wrong source line. A pure insertion
/// (`expected.len == 0`) has nothing to verify.
fn sourceLinesMatch(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    start: u32,
    expected: []const []const u8,
) !bool {
    if (expected.len == 0) return true;
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch return false;
    const lines = try mox.diff.lines.splitLines(arena, content);
    if (@as(usize, start) + expected.len > lines.len) return false;
    for (expected, 0..) |e, i| {
        if (!std.mem.eql(u8, e, lines[start + i])) return false;
    }
    return true;
}

/// True when `path` lives under the private layer root. A private-ONLY whole
/// file composes as `.base` (it is a base file of the private tree), so the
/// provenance tag alone cannot flag it; its location must. Any edit under the
/// private root is private-origin and must never couple into the shared repo.
fn isUnderPrivate(path: []const u8, private_dir: []const u8) bool {
    if (private_dir.len == 0) return false;
    if (!std.mem.startsWith(u8, path, private_dir)) return false;
    return path.len == private_dir.len or std.fs.path.isSep(path[private_dir.len]);
}

fn lineRoute(
    arena: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    start: u32,
    del: u32,
    new_lines: []const []const u8,
    shared: bool,
    private: bool,
) !Route {
    const desc = try std.fmt.allocPrint(arena, "{s}:{d}", .{ label, start + 1 });
    return .{ .line = .{
        .edit = .{ .path = path, .start = start, .del = del, .new_lines = new_lines, .private = private },
        .desc = desc,
        .shared = shared,
    } };
}

/// True when `path` is one of `file`'s Cat B region fragments (axis-gated),
/// distinguishing it from a universal include/append/prepend fragment.
fn isRegionFragment(file: mox.source.tree.ManagedFile, path: []const u8) bool {
    for (file.regions) |region| {
        for (region.fragments) |frag| {
            if (std.mem.eql(u8, frag.path, path)) return true;
        }
    }
    return false;
}

/// Find the managed file with `live_path` in a walked tree, or null.
fn findByLive(tree: mox.source.tree.ManagedTree, live_path: []const u8) ?mox.source.tree.ManagedFile {
    for (tree.files) |f| {
        if (std.mem.eql(u8, f.live_path, live_path)) return f;
    }
    return null;
}

/// Ask where a shared-origin (base / universal-fragment) line edit belongs.
///
/// Narrowing is an INTENT, not an impact fact: whether `export EDITOR=nvim`
/// should hold everywhere or only on darwin is something only the user knows,
/// and it cannot be deduced from what the edit currently changes -- a routable
/// base line is top-level, so it composes into every configuration the file
/// composes into at all. So every such hunk is asked, with universal as the
/// default (`--yes` commits universally, `--abort-on-prompt` exits 2).
///
/// Impact analysis still runs, but for INFORMATION and for verification: the
/// notice names what else the edit reaches, and the labels a choice is allowed
/// to change seed the post-write guard.
fn classifyLine(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: LineEdit, desc: []const u8, space: FileSpace) !Decision {
    const imp = try simulateImpact(cc, file, edit, space.configs);
    const notice = try impactNotice(cc.arena, file.live_path, imp, space.configs.len - 1);
    const cands = try candidates.compute(cc.arena, cc.this_bindings, space.ax);

    if (cc.report_mode) {
        try cc.stdout.writeAll(notice);
        try writeCandidates(cc.arena, cc.stdout, cands, cc.hostname);
        return .report;
    }

    var choices: std.ArrayList(prompt.Choice) = .empty;
    for (cands, 0..) |_, i| {
        try choices.append(cc.arena, .{ .key = try std.fmt.allocPrint(cc.arena, "{d}", .{i + 1}), .label = "" });
    }
    try choices.append(cc.arena, .{ .key = "m", .label = "manual" });
    try choices.append(cc.arena, .{ .key = "s", .label = "skip" });

    var qw: Io.Writer.Allocating = .init(cc.arena);
    try qw.writer.writeAll(notice);
    try writeCandidates(cc.arena, &qw.writer, cands, cc.hostname);
    try qw.writer.writeAll("  choose> ");
    const question = try qw.toOwnedSlice();

    switch (try prompt.ask(cc.ask_mode, choices.items, 0, question, cc.input, cc.stdout)) {
        .chosen => |i| {
            if (i < cands.len) return classifyChoice(cc, file, edit, desc, imp, cands[i], space.configs);
            if (i == cands.len) return .manual;
            return .skip;
        },
        .abort => return .abort,
        .abort_strict => return .abort_strict,
        .report_only => return .report,
    }
}

/// The impact line that heads the intent question: what else, beyond this
/// machine's own configuration, the edit reaches as it stands.
fn impactNotice(arena: std.mem.Allocator, live_path: []const u8, imp: impact.Impact, n_other: usize) ![]const u8 {
    if (n_other > 0 and imp.affected.len >= n_other)
        return std.fmt.allocPrint(arena, "  {s} -- this edit changes every configuration. Keep it universal, or narrow it?\n", .{live_path});
    if (imp.affected.len == 0)
        return std.fmt.allocPrint(arena, "  {s} -- this edit changes no other configuration (of {d} known configurations).\n", .{ live_path, n_other });
    return std.fmt.allocPrint(
        arena,
        "  {s} -- this also changes {s} (of {d} known configurations).\n",
        .{ live_path, try joinLabels(arena, imp.affected), n_other },
    );
}

/// Comma-join configuration labels for a notice/question line.
fn joinLabels(arena: std.mem.Allocator, labels: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (labels, 0..) |l, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, l);
    }
    return out.toOwnedSlice(arena);
}

/// Materialize a chosen candidate into a decision. Universal keeps the origin;
/// an axis or machine-local choice narrows a BASE edit via region synthesis;
/// private and non-base narrowings have no automatic route yet.
fn classifyChoice(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    edit: LineEdit,
    desc: []const u8,
    imp: impact.Impact,
    c: candidates.Candidate,
    configs: []const Configuration,
) !Decision {
    if (c.kind == .universal) return .{ .origin = imp.affected };

    const is_base = file.has_base and std.mem.eql(u8, edit.path, file.source_base_abs);
    if (c.kind == .private or !is_base) {
        try cc.stdout.print("  {s}: no automatic route to {s}; left uncommitted (edit the source manually)\n", .{ desc, try candidateLabel(cc.arena, c, cc.hostname) });
        return .unroutable;
    }

    const marker = markerFor(file.source_base_path) orelse {
        try cc.stdout.print("  {s}: unknown comment marker; cannot synthesize a region; left uncommitted\n", .{desc});
        return .unroutable;
    };
    const base_content = try Io.Dir.cwd().readFileAlloc(cc.io, edit.path, cc.arena, .limited(max_file_bytes));
    // A machine-local narrowing gates on this machine's own hostname, which
    // Candidate no longer carries (there is no machine axis to name).
    const axis_name = if (c.kind == .machine_local) "machine" else c.axis_name;
    const axis_value = if (c.kind == .machine_local) cc.hostname else c.axis_value;
    // Some narrowings cannot be synthesized without damaging or losing data:
    // one that wraps line 1 displaces a shebang or a whole-file gate, one
    // whose region name the file already uses hands its fragment to that
    // existing region as well, and one whose fragment path already holds a
    // leftover file would silently overwrite it. Refuse rather than corrupt
    // or destroy the source: the hunk stays uncommitted, like any other
    // unroutable narrowing.
    if (try mox.classify.synth.hazardOf(cc.arena, cc.io, edit.path, base_content, marker, edit.start, edit.del, axis_name, axis_value)) |hz| {
        try cc.stdout.print("  {s}: {s}; left uncommitted (edit the source manually)\n", .{ desc, try hz.message(cc.arena) });
        return .unroutable;
    }
    const plan = try mox.classify.synth.planRegion(
        cc.arena,
        edit.path,
        base_content,
        marker,
        edit.start,
        edit.del,
        edit.new_lines,
        axis_name,
        axis_value,
    );
    // A region or fragment an EARLIER hunk of this same commit will create is
    // as real as one already on disk: the second narrowing to it is refused the
    // same way, and its hunk stays uncommitted.
    if (try cc.claims.hazard(cc.arena, edit.path, plan.region, plan.fragment_path)) |msg| {
        try cc.stdout.print("  {s}: {s}; left uncommitted (edit the source manually)\n", .{ desc, msg });
        return .unroutable;
    }
    try cc.claims.add(cc.arena, edit.path, plan.region, plan.fragment_path);
    // Only an axis narrowing is allowed to change other configurations
    // (those sharing its value); a machine-local narrowing gates on this
    // machine alone, so no sibling configuration may change.
    const allowed: []const []const u8 = if (c.kind == .axis)
        try configsMatchingAxis(cc.arena, configs, c.axis_name, c.axis_value)
    else
        &.{};
    return .{ .synth = .{ .plan = plan, .base_abs = edit.path, .allowed = allowed } };
}

/// Labels of sibling configurations whose binding for `name` equals `value`,
/// so a chosen axis narrowing can scope which siblings it is expected to
/// change.
fn configsMatchingAxis(arena: std.mem.Allocator, configs: []const Configuration, name: []const u8, value: []const u8) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    for (configs) |cfg| {
        if (cfg.is_this_machine) continue;
        const v = cfg.bindings.get(name) orelse continue;
        if (std.mem.eql(u8, v, value)) try labels.append(arena, cfg.label);
    }
    return labels.toOwnedSlice(arena);
}

/// Comment marker for a source path, or null when the dialect is unknown.
fn markerFor(path: []const u8) ?[]const u8 {
    return mox.dsl.comment.markerForExtension(identForMarker(path));
}

/// Identifier for `comment.markerForExtension`: a dotfile with no further dot
/// (`.zshrc`) or an un-dotted basename (`Dockerfile`) is itself; otherwise the
/// trailing extension (`.lua`).
fn identForMarker(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return basename;
    if (basename[0] == '.') {
        const rest = basename[1..];
        if (std.mem.indexOfScalar(u8, rest, '.') == null) return basename;
    }
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[dot..];
}

/// Run impact analysis for one line edit: snapshot every configuration's
/// compose, transiently write the edited source, snapshot again, then restore.
/// The transient write is always reverted, so the abort-writes-nothing contract
/// holds.
fn simulateImpact(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: LineEdit, configs: []const Configuration) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const original = try Io.Dir.cwd().readFileAlloc(io, edit.path, arena, .limited(max_file_bytes));
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    const edited = try editedContent(arena, original, edit);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = edited });
    const after = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = original }) catch {};
        return e;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = original });

    return impact.impact(arena, configs, before, after);
}

/// Run impact analysis for one loop-row edit: snapshot every configuration's
/// compose, transiently rewrite the row in its data source, snapshot again, then
/// restore. The transient write is always reverted.
fn simulateRowImpact(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: RowEdit, configs: []const Configuration) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const original = try Io.Dir.cwd().readFileAlloc(io, edit.data_source, arena, .limited(max_file_bytes));
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    const edited = try updateTomlRow(arena, original, edit.stem, edit.row, edit.fields);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = edited });
    const after = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = original }) catch {};
        return e;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = original });

    return impact.impact(arena, configs, before, after);
}

/// Apply one line edit to `content` in memory, preserving its trailing-newline
/// shape. Mirrors `applyLineEdits` for a single splice.
fn editedContent(arena: std.mem.Allocator, content: []const u8, edit: LineEdit) ![]u8 {
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';
    var lines: std.ArrayList([]const u8) = .empty;
    for (try mox.diff.lines.splitLines(arena, content)) |l| try lines.append(arena, l);
    const start = @min(edit.start, lines.items.len);
    const end = @min(start + edit.del, lines.items.len);
    try lines.replaceRange(arena, start, end - start, edit.new_lines);

    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |l, idx| {
        if (idx > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
    }
    if (had_trailing_nl and lines.items.len > 0) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// Render one prompt/report line per candidate plus the manual/skip/quit tail.
fn writeCandidates(arena: std.mem.Allocator, w: *Io.Writer, cands: []const candidates.Candidate, hostname: []const u8) !void {
    for (cands, 0..) |c, i| {
        try w.print("    [{d}] {s}\n", .{ i + 1, try candidateLabel(arena, c, hostname) });
    }
    try w.writeAll("    [m] manual  [s] skip  [q] quit\n");
}

/// Human-readable label for a candidate.
fn candidateLabel(arena: std.mem.Allocator, c: candidates.Candidate, hostname: []const u8) ![]const u8 {
    return switch (c.kind) {
        .universal => "universal",
        .axis => c.label,
        .machine_local => try std.fmt.allocPrint(arena, "machine={s} (only here)", .{hostname}),
        .private => "private",
    };
}

/// Parse `line` against a single-line loop `template`, returning the field
/// updates for its `<entry.X>` / bare captures, or null when the line does not
/// match the template's literal frame. Captures against `<machine.X>` /
/// `<env.X>` are skipped (their value is machine-derived, not row data).
/// Templates are linted to forbid adjacent captures, so every interior
/// literal is non-empty, which makes the greedy match unambiguous.
fn reverseTemplate(arena: std.mem.Allocator, template: []const u8, line: []const u8) !?[]const Field {
    var literals: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < template.len) {
        if (template[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            try literals.append(arena, template[lit_start..i]);
            try names.append(arena, template[i + 1 .. close]);
            i = close + 1;
            lit_start = i;
            continue;
        }
        i += 1;
    }
    try literals.append(arena, template[lit_start..]);

    // No captures: a match is only a literal-equality check, yielding no
    // field updates.
    if (names.items.len == 0) {
        if (std.mem.eql(u8, template, line)) return &.{};
        return null;
    }

    var values = try arena.alloc([]const u8, names.items.len);
    var pos: usize = 0;
    if (!std.mem.startsWith(u8, line, literals.items[0])) return null;
    pos += literals.items[0].len;

    for (names.items, 0..) |_, ci| {
        const delim = literals.items[ci + 1];
        const is_last = ci == names.items.len - 1;
        if (is_last) {
            if (delim.len == 0) {
                values[ci] = line[pos..];
                pos = line.len;
            } else {
                if (line.len < pos + delim.len) return null;
                if (!std.mem.endsWith(u8, line, delim)) return null;
                values[ci] = line[pos .. line.len - delim.len];
                pos = line.len;
            }
        } else {
            if (delim.len == 0) return null;
            const idx = std.mem.indexOfPos(u8, line, pos, delim) orelse return null;
            values[ci] = line[pos..idx];
            pos = idx + delim.len;
        }
    }

    var fields: std.ArrayList(Field) = .empty;
    for (names.items, 0..) |name, ci| {
        const field = captureField(name) orelse continue;
        try fields.append(arena, .{ .name = field, .value = values[ci] });
    }
    return try fields.toOwnedSlice(arena);
}

/// Field name a capture maps to in the data row, or null when the capture is
/// machine-derived (`machine.`/`env.`) and thus not row data.
fn captureField(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "entry.")) return name[6..];
    if (std.mem.startsWith(u8, name, "machine.")) return null;
    if (std.mem.startsWith(u8, name, "env.")) return null;
    if (std.mem.indexOf(u8, name, " | ") != null) return null;
    return name;
}

/// Apply all line edits, grouped by physical file, so a file is rewritten once
/// with every edit that targets it.
fn applyLineEdits(arena: std.mem.Allocator, io: Io, edits: []const LineEdit) !void {
    var done: std.ArrayList([]const u8) = .empty;
    for (edits) |e| {
        var seen = false;
        for (done.items) |p| {
            if (std.mem.eql(u8, p, e.path)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try done.append(arena, e.path);

        var file_edits: std.ArrayList(LineEdit) = .empty;
        for (edits) |fe| {
            if (std.mem.eql(u8, fe.path, e.path)) try file_edits.append(arena, fe);
        }
        const content = try splicedContent(arena, io, e.path, file_edits.items);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = e.path, .data = content });
    }
}

/// `path`'s CURRENT bytes with every splice in `edits` applied. Each splice
/// indexes the file's pre-write lines, so they are applied high-index-first: an
/// earlier splice never shifts a later one's range. The trailing-newline shape
/// is preserved.
fn splicedContent(arena: std.mem.Allocator, io: Io, path: []const u8, edits: []const LineEdit) ![]const u8 {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes));
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';

    var lines: std.ArrayList([]const u8) = .empty;
    for (try mox.diff.lines.splitLines(arena, content)) |l| try lines.append(arena, l);

    const ordered = try arena.dupe(LineEdit, edits);
    std.mem.sort(LineEdit, ordered, {}, cmpEditDesc);
    for (ordered) |fe| {
        const start = @min(fe.start, lines.items.len);
        const end = @min(start + fe.del, lines.items.len);
        try lines.replaceRange(arena, start, end - start, fe.new_lines);
    }

    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |l, idx| {
        if (idx > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
    }
    if (had_trailing_nl and lines.items.len > 0) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// The distinct base files the accepted narrowings rewrite, in order.
fn synthBases(arena: std.mem.Allocator, plans: []const SynthDecision) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (plans) |sd| {
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p, sd.base_abs)) seen = true;
        }
        if (!seen) try out.append(arena, sd.base_abs);
    }
    return out.toOwnedSlice(arena);
}

/// The line edits that do NOT target one of `paths`. A base with narrowings is
/// written by `synth.materialize` instead, in one pass with its region blocks.
fn lineEditsExcluding(arena: std.mem.Allocator, edits: []const LineEdit, paths: []const []const u8) ![]const LineEdit {
    var out: std.ArrayList(LineEdit) = .empty;
    for (edits) |e| {
        var excluded = false;
        for (paths) |p| {
            if (std.mem.eql(u8, p, e.path)) excluded = true;
        }
        if (!excluded) try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

fn cmpEditDesc(_: void, a: LineEdit, b: LineEdit) bool {
    return a.start > b.start;
}

/// Apply all row edits, grouped by data source, rewriting each changed
/// `key = value` line in place.
fn applyRowEdits(arena: std.mem.Allocator, io: Io, edits: []const RowEdit) !void {
    var done: std.ArrayList([]const u8) = .empty;
    for (edits) |e| {
        var seen = false;
        for (done.items) |p| {
            if (std.mem.eql(u8, p, e.data_source)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try done.append(arena, e.data_source);

        var content = try Io.Dir.cwd().readFileAlloc(io, e.data_source, arena, .limited(max_file_bytes));
        for (edits) |re| {
            if (!std.mem.eql(u8, re.data_source, e.data_source)) continue;
            content = try updateTomlRow(arena, content, re.stem, re.row, re.fields);
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = e.data_source, .data = content });
    }
}

/// Rewrite the `key = "value"` lines of the `target_row`-th `[[stem]]` table,
/// changing only fields whose value actually differs. Returns arena-owned
/// bytes; unrelated rows and fields are preserved verbatim.
fn updateTomlRow(
    arena: std.mem.Allocator,
    content: []const u8,
    stem: []const u8,
    target_row: u32,
    fields: []const Field,
) ![]u8 {
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';
    var out: std.ArrayList(u8) = .empty;

    var row_counter: i64 = -1;
    var in_target = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        // Drop the phantom empty segment a trailing newline produces.
        if (lines.peek() == null and line.len == 0 and had_trailing_nl) break;
        if (!first) try out.append(arena, '\n');
        first = false;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "[[")) {
            const close = std.mem.indexOf(u8, trimmed, "]]");
            if (close) |c| {
                const name = std.mem.trim(u8, trimmed[2..c], " \t");
                if (std.mem.eql(u8, name, stem)) {
                    row_counter += 1;
                    in_target = row_counter == target_row;
                } else {
                    in_target = false;
                }
            }
            try out.appendSlice(arena, line);
            continue;
        }

        if (in_target) {
            if (rewriteField(arena, line, fields)) |replaced| {
                try out.appendSlice(arena, replaced);
                continue;
            } else |_| {}
        }
        try out.appendSlice(arena, line);
    }

    if (had_trailing_nl) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// If `line` assigns one of `fields`, return the line with the new value; a
/// null-value sentinel error means "not a matching assignment, leave it".
fn rewriteField(arena: std.mem.Allocator, line: []const u8, fields: []const Field) ![]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.NotAField;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    for (fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            const indent_len = line.len - std.mem.trimStart(u8, line, " \t").len;
            const rebuilt = try std.fmt.allocPrint(arena, "{s}{s} = \"{s}\"", .{ line[0..indent_len], key, f.value });
            return rebuilt;
        }
    }
    return error.NotAField;
}

/// Stem of a filename: basename without its trailing extension.
fn filenameStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[0..dot];
}

fn printMiniDiff(out: *Io.Writer, hunk: Hunk, a_lines: []const []const u8, b_lines: []const []const u8) !void {
    var i: u32 = 0;
    while (i < hunk.a_len) : (i += 1) try out.print("    - {s}\n", .{a_lines[hunk.a_start + i]});
    i = 0;
    while (i < hunk.b_len) : (i += 1) try out.print("    + {s}\n", .{b_lines[hunk.b_start + i]});
}

pub const command = app.command(Spec, .{
    .name = "commit",
    .summary = "Route live-file edits back into their sources",
    .details = "Prompts [Y/n/m] per hunk (--yes: take defaults; --dry-run: report only, exit 1 if edits remain; --abort-on-prompt: strict CI, rc 2 on the first prompt). Private-origin edits go only to the private layer, never repo src. A shared edit that would change only some of the file's own configurations prompts to keep it universal or narrow it to an axis (synthesizing a region); a changed token shared by other sources prompts to update them too.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "reverseTemplate: extracts entry captures from a matching line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fields = (try reverseTemplate(arena.allocator(), "abbr <entry.key>=\"<entry.expansion>\"", "abbr gs=\"git status -sb\"")).?;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("key", fields[0].name);
    try testing.expectEqualStrings("gs", fields[0].value);
    try testing.expectEqualStrings("expansion", fields[1].name);
    try testing.expectEqualStrings("git status -sb", fields[1].value);
}

test "reverseTemplate: non-matching frame returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try reverseTemplate(arena.allocator(), "abbr <entry.key>=\"<entry.expansion>\"", "alias gs=git") == null);
}

test "reverseTemplate: trailing capture consumes the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fields = (try reverseTemplate(arena.allocator(), "export <entry.name>", "export PATH=/usr/bin")).?;
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("PATH=/usr/bin", fields[0].value);
}

test "reverseTemplate: machine captures are not field updates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fields = (try reverseTemplate(arena.allocator(), "<entry.key> on <machine.os>", "ll on linux")).?;
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("key", fields[0].name);
    try testing.expectEqualStrings("ll", fields[0].value);
}

test "updateTomlRow: changes only the target row's changed field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status"
        \\
    ;
    const fields = [_]Field{
        .{ .name = "key", .value = "gs" },
        .{ .name = "expansion", .value = "git status -sb" },
    };
    const out = try updateTomlRow(arena.allocator(), src, "abbrs", 1, &fields);
    const expected =
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\
    ;
    try testing.expectEqualStrings(expected, out);
}

test "applyCouplingEdits: renames only complete-token occurrences, not superstrings" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const target = try std.fs.path.join(a, &.{ base, "target" });
    // The coupled token appears standalone AND as the prefix of a longer token
    // (`coupledtoken_extra` is one token because `_` is a token char).
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "value = coupledtoken\nother = coupledtoken_extra\n" });

    const edits = [_]CouplingEdit{.{ .path = target, .old = "coupledtoken", .new = "newtoken" }};
    try applyCouplingEdits(a, io, &edits);

    // Only the standalone token is renamed; the superstring is left intact.
    const got = try Io.Dir.cwd().readFileAlloc(io, target, a, .limited(max_file_bytes));
    try testing.expectEqualStrings("value = newtoken\nother = coupledtoken_extra\n", got);
}

/// One configuration with the given label and bindings, for the tests below.
fn testConfig(a: std.mem.Allocator, label: []const u8, pairs: []const [2][]const u8, is_this: bool) !Configuration {
    var b = std.StringHashMap([]const u8).init(a);
    for (pairs) |p| try b.put(p[0], p[1]);
    return .{ .label = label, .bindings = b, .is_this_machine = is_this };
}

test "configsMatchingAxis: scopes a narrowing to the siblings sharing its axis value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This machine is os=darwin+profile=personal; the other three configurations
    // are its siblings in the {os} x {profile} space.
    const configs = [_]Configuration{
        try testConfig(a, "", &.{ .{ "os", "darwin" }, .{ "profile", "personal" } }, true),
        try testConfig(a, "os=darwin+profile=work", &.{ .{ "os", "darwin" }, .{ "profile", "work" } }, false),
        try testConfig(a, "os=linux+profile=personal", &.{ .{ "os", "linux" }, .{ "profile", "personal" } }, false),
        try testConfig(a, "os=linux+profile=work", &.{ .{ "os", "linux" }, .{ "profile", "work" } }, false),
    };

    // Narrowing to os=darwin may change exactly the OTHER darwin configuration:
    // never this machine (which is not a sibling to verify against), and never a
    // linux one -- naming either would let a real divergence through the guard.
    const darwin = try configsMatchingAxis(a, &configs, "os", "darwin");
    try testing.expectEqual(@as(usize, 1), darwin.len);
    try testing.expectEqualStrings("os=darwin+profile=work", darwin[0]);

    // Narrowing to profile=personal reaches the other personal configuration only.
    const personal = try configsMatchingAxis(a, &configs, "profile", "personal");
    try testing.expectEqual(@as(usize, 1), personal.len);
    try testing.expectEqualStrings("os=linux+profile=personal", personal[0]);
}

test "configsMatchingAxis: a value no sibling holds, and an axis a config lacks, allow nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = [_]Configuration{
        try testConfig(a, "", &.{.{ "os", "darwin" }}, true),
        // A sibling that does not bind `profile` at all (the axis is unset there).
        try testConfig(a, "os=linux", &.{.{ "os", "linux" }}, false),
    };

    // No sibling is os=darwin: a machine-only narrowing may change nothing.
    try testing.expectEqual(@as(usize, 0), (try configsMatchingAxis(a, &configs, "os", "darwin")).len);
    // The sibling has no `profile` binding, so it is not swept in by a
    // profile narrowing (which would silently license a change to it).
    try testing.expectEqual(@as(usize, 0), (try configsMatchingAxis(a, &configs, "profile", "personal")).len);
}

test "resolveCoupling: an occurrence in a protected source is skipped, never offered" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const edited = try std.fs.path.join(a, &.{ base, "edited" });
    const protected_src = try std.fs.path.join(a, &.{ base, "seed" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = protected_src, .data = "old@example.com seed\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", protected_src, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = edited, .start = 0, .del = 1, .new_lines = &.{"new@example.com"} };
    // "Y" would ACCEPT the update if the occurrence were ever offered.
    var reader = Io.Reader.fixed("Y\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var protected = std.StringHashMap(void).init(a);
    try protected.put(protected_src, {});

    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &protected, .interactive, &reader, &out_aw.writer);

    // Skipped before the prompt: no edit, no announcement, no abort. Without
    // the skip, "Y" would have queued an edit for the protected source.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
    try testing.expect(!res.abort);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "update") == null);
}

test "resolveCoupling: a private-origin rename never couples into a shared source" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    // The edited file is a PRIVATE-layer source; the shared repo source holds
    // the same token and is NOT protected (not a symlink/seed source).
    const private_src = try std.fs.path.join(a, &.{ base, "private" });
    const shared_src = try std.fs.path.join(a, &.{ base, "shared" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = private_src, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = shared_src, .data = "old@example.com base\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", shared_src, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = private_src, .start = 0, .del = 1, .new_lines = &.{"new@example.com"}, .private = true };
    // "Y" would ACCEPT the sync into the shared source if it were ever offered:
    // this is the private->shared leak the skip must prevent.
    var reader = Io.Reader.fixed("Y\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var no_protected = std.StringHashMap(void).init(a);

    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &no_protected, .interactive, &reader, &out_aw.writer);

    // Skipped before any prompt: no edit into the shared source, no announcement.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
    try testing.expect(!res.abort);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "update") == null);
    // And the read-only reporter must likewise offer nothing.
    var report_protected = std.StringHashMap(void).init(a);
    var report_aw: Io.Writer.Allocating = .init(a);
    const reported = try reportCoupling(a, io, coupling_dir, &.{edit}, &report_protected, &report_aw.writer);
    try testing.expectEqual(@as(usize, 0), reported);
}

test "isUnderPrivate: boundary-aware membership" {
    try testing.expect(isUnderPrivate("/h/.priv/.token", "/h/.priv"));
    try testing.expect(isUnderPrivate("/h/.priv", "/h/.priv")); // the root itself
    try testing.expect(!isUnderPrivate("/h/.private-other/x", "/h/.priv")); // sibling sharing a prefix
    try testing.expect(!isUnderPrivate("/h/src/.token", "/h/.priv"));
    try testing.expect(!isUnderPrivate("/h/src/.token", "")); // no private layer
}

test "routeHunk: a private-only base file's edit is flagged private by location" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const private_dir = try std.fs.path.join(a, &.{ base, "private" });
    const src_abs = try std.fs.path.join(a, &.{ private_dir, ".token" });
    try Io.Dir.cwd().createDirPath(io, private_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_abs, .data = "key = old\n" });

    // A private-only whole file composes as `.base` origin, yet its source lives
    // under the private root -- the route must still mark it private.
    const file: mox.source.tree.ManagedFile = .{
        .source_base_path = ".token",
        .source_base_abs = src_abs,
        .live_path = try std.fs.path.join(a, &.{ base, "home", ".token" }),
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .private_dir = private_dir,
    };
    var segs = [_]mox.provenance.map.Segment{.{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } }};
    const hunk: mox.diff.lines.Hunk = .{ .a_start = 0, .a_len = 1, .b_start = 0, .b_len = 1 };
    const a_lines = [_][]const u8{"key = old"};
    const b_lines = [_][]const u8{"key = new"};

    const route = try routeHunk(a, io, &segs, hunk, file, &a_lines, &b_lines);
    try testing.expect(route == .line);
    try testing.expect(route.line.edit.private);
}

test "resolveCoupling: a q-abort after a decline persists no decline" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One routed rename (old@example.com -> new@example.com) whose old token
    // still lives in TWO other managed sources, so it yields two coupling
    // prompts. The user declines the first (d) then quits (q).
    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const edited = try std.fs.path.join(a, &.{ base, "edited" });
    const other1 = try std.fs.path.join(a, &.{ base, "other1" });
    const other2 = try std.fs.path.join(a, &.{ base, "other2" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = other1, .data = "old@example.com signing\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = other2, .data = "old@example.com allowed\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", other1, 0, 15);
    try g.addOccurrence("old@example.com", other2, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = edited, .start = 0, .del = 1, .new_lines = &.{"new@example.com"} };
    var reader = Io.Reader.fixed("d\nq\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var no_protected = std.StringHashMap(void).init(a);

    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &no_protected, .interactive, &reader, &out_aw.writer);

    // The user quit at the second prompt: the command aborts.
    try testing.expect(res.abort);
    // A decline WAS entered on the first prompt...
    try testing.expect(res.declines.isPairDeclined("old@example.com", edited, other1));
    // ...but because the whole command aborted, nothing may persist: the
    // caller saves the decline list only when save_declines is set.
    try testing.expect(!res.save_declines);
    // No coupling edit was accepted either.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
}
