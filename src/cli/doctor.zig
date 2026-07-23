//! `mox doctor`: report on the health of the mox repo and machine-local state,
//! and optionally rebuild derived state.
//!
//! Checks: source files not tracked by git, source modes git cannot carry that
//! are not yet recorded in `.mox/attributes.toml` (lost on clone), and state
//! files that fail their format read (malformed provenance). `--rebuild-provenance`
//! recomposes every recorded file and re-records its provenance; `--fix`
//! performs the safe rebuilds. `--rebuild-coupling` rescans source tokens and
//! reports the coupling counts. Mutating runs take the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const max_state_bytes: usize = 64 * 1024 * 1024;

/// Scan `<state>/provenance/` and return the paths of files that fail to
/// deserialize (malformed / wrong-version state). Arena-owned.
pub fn findMalformedProvenance(arena: std.mem.Allocator, io: Io, state_dir: []const u8) ![]const []const u8 {
    const prov_dir = try std.fs.path.join(arena, &.{ state_dir, "provenance" });
    var dir = Io.Dir.cwd().openDir(io, prov_dir, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    // Sorted so the advisory lists the same malformed files in the same order
    // on every machine.
    for (try mox.source.dirent.sorted(arena, io, dir)) |entry| {
        if (entry.kind != .file) continue;
        const content = dir.readFileAlloc(io, entry.name, arena, .limited(max_state_bytes)) catch continue;
        if (mox.provenance.map.deserialize(arena, content)) |_| {} else |_| {
            try out.append(arena, try std.fs.path.join(arena, &.{ prov_dir, entry.name }));
        }
    }
    return out.toOwnedSlice(arena);
}

const Spec = struct {
    fix: cli.spec.Flag(.{ .help = "perform the safe rebuilds" }),
    rebuild_provenance: cli.spec.Flag(.{ .help = "recompose every recorded file and re-record its provenance" }),
    rebuild_coupling: cli.spec.Flag(.{ .help = "rescan source tokens and rebuild the coupling graph" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const fix = a.fix;
    const rebuild_prov = fix or a.rebuild_provenance;
    const rebuild_coupling = fix or a.rebuild_coupling;
    const mutating = rebuild_prov or rebuild_coupling;

    var lk: ?lock_mod.Lock = null;
    if (mutating) {
        lk = (try lock_mod.acquireForCommand(ctx, "doctor")) orelse return 1;
    }
    defer if (lk) |l| l.release();

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });

    // `problems` are the rebuildable breakage the rc gates on and `--fix`
    // remediates (malformed provenance). `advisories` are findings mox reports
    // but deliberately does not auto-remediate (untracked sources); they never
    // set the exit code, so the rc is consistent whether or not `--fix` ran.
    var advisories: usize = 0;

    // Source files not tracked by git. Null means the check could not run (the
    // repo is not a git working tree, or git is unavailable): note that, so a
    // clean report never implies every source is tracked when it was not checked.
    if (try gitUntrackedSrc(ctx.alloc, ctx.io, context.paths.repo_dir)) |untracked| {
        for (untracked) |u| {
            advisories += 1;
            try ctx.out.print("  untracked {s} (source not tracked by git)\n", .{u});
        }
    } else {
        try ctx.out.print("  note: {s} is not a git working tree; the tracked-source check was skipped\n", .{context.paths.repo_dir});
    }

    // Source modes git cannot carry (not 0644/0755) that are not recorded in
    // `.mox/attributes.toml`: git collapses them on clone, so the mode is lost.
    const unrecorded = unrecordedModes(ctx.alloc, ctx.io, context.paths.repo_dir, src_dir) catch &.{};
    for (unrecorded) |key| {
        advisories += 1;
        try ctx.out.print("  unrecorded-mode {s} (source mode is not 0644/0755 and not in .mox/attributes.toml; lost on clone -- re-run 'mox add' or record it)\n", .{key});
    }

    // Sources that compose to null under every configuration in their own axis
    // space: gated off on every machine, so they never materialize anywhere --
    // almost always a contradictory or mistyped `# mox: when` gate.
    for (try neverMaterializing(ctx.alloc, ctx.io, src_dir, context)) |dead| {
        advisories += 1;
        try ctx.out.print("  never-materializes {s} (composes to nothing under every configuration; check its whole-file gate)\n", .{dead});
    }

    // Generators whose data source is missing or whose rows collide on a
    // rendered path: they would fail (or drop a file) at apply time.
    for (try generatorProblems(ctx.alloc, ctx.io, src_dir, context)) |msg| {
        advisories += 1;
        try ctx.out.print("  generator {s}\n", .{msg});
    }

    // Tracked sources that also match an ignore rule: a contradiction the user
    // should resolve, since the source is tracked but will never be applied.
    for (try trackedAndIgnored(ctx.alloc, ctx.io, src_dir, context)) |p| {
        advisories += 1;
        try ctx.out.print("  tracked-and-ignored {s} (matches an ignore rule; it will not be applied -- remove one)\n", .{p});
    }

    // Malformed provenance records (rebuildable).
    const bad_prov = try findMalformedProvenance(ctx.alloc, ctx.io, context.paths.state_dir);
    var problems = bad_prov.len;
    for (bad_prov) |p| {
        try ctx.out.print("  bad-provenance {s} (fails to read)\n", .{p});
    }

    if (rebuild_prov) {
        const rebuilt = try rebuildProvenance(ctx, src_dir);
        try ctx.out.print("  rebuilt provenance for {d} recorded file(s)\n", .{rebuilt});
        // A successful rebuild re-writes every recorded file's provenance, so
        // re-check whether any malformed records remain.
        problems = (try findMalformedProvenance(ctx.alloc, ctx.io, context.paths.state_dir)).len;
    }

    if (rebuild_coupling) {
        const counts = try rescanCoupling(ctx, src_dir);
        try ctx.out.print("  coupling: {d} coupled token(s) across source files\n", .{counts});
    }

    if (problems > 0) {
        try ctx.out.print("mox doctor: {d} problem(s) found\n", .{problems});
    } else if (advisories > 0) {
        // Advisories are soft (exit 0), but the report is not "healthy" when it
        // has items needing manual attention -- say so without contradicting.
        try ctx.out.print("mox doctor: {d} advisory item(s) need attention\n", .{advisories});
    } else {
        try ctx.out.writeAll("mox doctor: healthy\n");
    }
    return if (problems > 0) 1 else 0;
}

/// Source files that compose to null under every configuration in their own
/// axis space -- gated off on every machine, so they never materialize. Any
/// step that cannot run (no source tree, capture failure) yields no findings
/// rather than an error, so doctor's other checks still report. Arena-owned
/// display paths.
fn neverMaterializing(
    arena: std.mem.Allocator,
    io: Io,
    src_dir: []const u8,
    context: app.Context,
) ![]const []const u8 {
    const m_state = mox.machine.state.capture(arena, io, context.env) catch return &.{};
    const this_bindings = try mox.machine.bindings.fromMachineState(arena, m_state);
    const base_tree = mox.source.tree.walk(arena, io, src_dir, m_state.home) catch return &.{};
    const tree = mox.private.layer.merge(arena, io, base_tree, context.paths.private_dir, m_state.home) catch base_tree;

    var out: std.ArrayList([]const u8) = .empty;
    for (tree.files) |file| {
        const ax = try mox.source.axes.ofFile(arena, io, file);
        // `enumerate` varies only compared axes. A file that also gates on a
        // presence or multi-value fact (`when signing_key`, `when tool=rg`)
        // materializes on a machine that has it, which the config space cannot
        // represent -- so a null-everywhere result there is not proof.
        if (!allNamesCompared(ax)) continue;
        const configs = try mox.classify.config_space.enumerate(arena, &this_bindings, ax, &.{}, &.{});
        const materializes = for (configs) |cfg| {
            const composed = mox.compose.composeFileTracked(arena, io, file, &cfg.bindings, &m_state, null, null, null) catch break true;
            if (composed != null) break true;
        } else false;
        if (!materializes) try out.append(arena, file.source_base_path);
    }
    return out.toOwnedSlice(arena);
}

/// Generators that would fail (or silently drop a file) at apply: a missing
/// data source, or two rows rendering the same path. Best-effort -- any step
/// that cannot run yields no findings. Arena-owned display strings.
fn generatorProblems(
    arena: std.mem.Allocator,
    io: Io,
    src_dir: []const u8,
    context: app.Context,
) ![]const []const u8 {
    const m_state = mox.machine.state.capture(arena, io, context.env) catch return &.{};
    const bindings = try mox.machine.bindings.fromMachineState(arena, m_state);
    const base_tree = mox.source.tree.walk(arena, io, src_dir, m_state.home) catch return &.{};
    const tree = mox.private.layer.merge(arena, io, base_tree, context.paths.private_dir, m_state.home) catch base_tree;

    var out: std.ArrayList([]const u8) = .empty;
    for (tree.files) |file| {
        var diag: mox.compose.interp.Diag = .{};
        // Read-path compose (no secret resolution): a generator's structure,
        // data source, and path collisions are all decided without secrets.
        _ = mox.compose.catB.composeGenerator(arena, io, file, &bindings, &m_state, null, &diag) catch |e| switch (e) {
            error.DataSourceNotFound, error.DataSourceArrayNotFound => {
                try out.append(arena, try std.fmt.allocPrint(arena, "{s}: data source missing ({s})", .{ file.source_base_path, diag.capture() orelse "?" }));
                continue;
            },
            error.DuplicateGeneratedPath => {
                try out.append(arena, try std.fmt.allocPrint(arena, "{s}: two rows render the same path ({s})", .{ file.source_base_path, diag.capture() orelse "?" }));
                continue;
            },
            error.GeneratedPathEscapes => {
                try out.append(arena, try std.fmt.allocPrint(arena, "{s}: a rendered path escapes its target dir ({s})", .{ file.source_base_path, diag.capture() orelse "?" }));
                continue;
            },
            else => continue,
        };
    }
    return out.toOwnedSlice(arena);
}

/// Tracked sources whose home-relative key matches an UNCONDITIONAL ignore
/// rule (one outside any `# mox: when` region), directly or via a containing
/// directory: tracked-but-ignored-everywhere is a real contradiction mox
/// surfaces rather than silently picking a side. A rule gated to other
/// machines (`# mox: when os=windows`) is intentional per-machine gating, not
/// a contradiction, so it is excluded here. Best-effort, like the other
/// checks -- any step that cannot run yields no findings. Arena-owned live paths.
fn trackedAndIgnored(
    arena: std.mem.Allocator,
    io: Io,
    src_dir: []const u8,
    context: app.Context,
) ![]const []const u8 {
    const m_state = mox.machine.state.capture(arena, io, context.env) catch return &.{};
    const base_tree = mox.source.tree.walk(arena, io, src_dir, m_state.home) catch return &.{};
    const tree = mox.private.layer.merge(arena, io, base_tree, context.paths.private_dir, m_state.home) catch base_tree;
    const ruleset = mox.source.ignore.load.loadUnconditional(arena, io, context.paths.repo_dir) catch return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    for (tree.files) |file| {
        const rel = try mox.source.path.liveKeyRelToHome(arena, m_state.home, file.live_path);
        if (ruleset.isPathIgnored(rel, false)) try out.append(arena, file.live_path);
    }
    return out.toOwnedSlice(arena);
}

/// Whether every axis the file references is a compared axis (one `enumerate`
/// varies). False when it gates on a presence-only or multi-value fact, whose
/// materializing configurations the enumerated space cannot reproduce.
fn allNamesCompared(ax: mox.source.axes.Axes) bool {
    var it = ax.names.keyIterator();
    while (it.next()) |n| {
        if (!ax.compared.contains(n.*)) return false;
    }
    return true;
}

/// Whether `rebuildProvenance` may refresh a file's provenance: only when the
/// current composition still hashes to what mox last applied. A mismatch means
/// the live file predates a source change, so rewriting its provenance from the
/// new source could strip a `.secret` tag that still guards resolved cleartext
/// sitting in the live file -- which would then leak through diff/snapshot/commit.
fn provenanceInSync(recorded: [mox.apply.applied.hash_hex_len]u8, composed: []const u8) bool {
    return std.mem.eql(u8, &recorded, &mox.apply.applied.contentHashHex(composed));
}

/// Recompose every managed file that has a last-applied record and re-persist
/// its provenance (and applied records). Returns the number rebuilt.
fn rebuildProvenance(ctx: *app.Ctx, src_dir: []const u8) !usize {
    const context = ctx.context.?;
    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch return 0;
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    var rebuilt: usize = 0;
    for (tree.files) |file| {
        if (file.is_symlink or file.create_once) continue;
        // Only rebuild for files mox actually tracks (have an applied record).
        const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
        if (recorded == null) continue;

        var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &prov, null) catch continue;
        const bytes = composed orelse continue;
        // Only rebuild when the live file still matches what mox last applied.
        // If the source changed since (e.g. a `<secret:...>` reference removed
        // while its resolved cleartext still sits in the live file), rewriting
        // provenance from the new source would drop the `.secret` guard.
        if (!provenanceInSync(recorded.?, bytes)) continue;
        // Never cache the cleartext of a secret-bearing composition.
        if (!mox.provenance.map.hasSecret(prov.items)) {
            try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, bytes);
        }
        try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, prov.items);
        rebuilt += 1;
    }
    return rebuilt;
}

/// Rescan source-file tokens, rebuild the coupling graph keyed by absolute
/// source path, and persist it under `<state>/coupling/`. Returns the count of
/// coupled (co-occurring) tokens.
fn rescanCoupling(ctx: *app.Ctx, src_dir: []const u8) !usize {
    const context = ctx.context.?;
    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch return 0;

    var inputs: std.ArrayList(mox.coupling.index.FileInput) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        // A symlink target / seed-once body is never token-synced, so keep it
        // out of the coupling graph entirely.
        if (file.is_symlink or file.create_once) continue;
        const content = Io.Dir.cwd().readFileAlloc(ctx.io, file.source_base_abs, ctx.alloc, .limited(max_state_bytes)) catch continue;
        try inputs.append(ctx.alloc, .{ .id = file.source_base_abs, .content = content });
    }
    var g = try mox.coupling.index.build(ctx.alloc, inputs.items);
    const coupling_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "coupling" });
    try mox.coupling.store.saveGraph(ctx.alloc, ctx.io, coupling_dir, &g);
    return g.map.count();
}

/// Source files present under `repo/src` but not tracked by git. Returns an
/// empty slice when the tree is fully tracked, and NULL when the check could not
/// run -- the repo is not a git working tree, or git is unavailable -- so the
/// caller can distinguish "all tracked" from "not checked".
fn gitUntrackedSrc(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !?[]const []const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{
        "git", "-C", repo_dir, "ls-files", "--others", "--exclude-standard", "--", "src",
    } }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        try out.append(arena, try arena.dupe(u8, t));
    }
    return try out.toOwnedSlice(arena);
}

/// Base source files whose on-disk mode git cannot carry (neither 0644 nor
/// 0755) and which `.mox/attributes.toml` does not record. git collapses such a
/// mode to 0644 on clone, so an unrecorded 0600/0444 source silently loses its
/// mode. Returns portable target keys. POSIX only -- a filesystem with no
/// executable bit (Windows) exposes no such modes, so the check is empty there.
/// Best-effort: an unwalkable tree or unreadable file yields no finding.
fn unrecordedModes(arena: std.mem.Allocator, io: Io, repo_dir: []const u8, src_dir: []const u8) ![]const []const u8 {
    if (!Io.File.Permissions.has_executable_bit) return &.{};

    const attrs = mox.source.attributes.load(arena, io, repo_dir) catch return &.{};
    const tree = mox.source.tree.walk(arena, io, src_dir, "") catch return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        const st = Io.Dir.cwd().statFile(io, file.source_base_abs, .{}) catch continue;
        const m = st.permissions.toMode() & 0o777;
        if (m == 0o644 or m == 0o755) continue;
        const key = if (std.mem.startsWith(u8, file.source_base_path, "src/"))
            file.source_base_path["src/".len..]
        else
            file.source_base_path;
        if (attrs.mode(key) != null) continue;
        try out.append(arena, key);
    }
    return out.toOwnedSlice(arena);
}

pub const command = app.command(Spec, .{
    .name = "doctor",
    .summary = "Health report on the mox repo and machine-local state",
    .details = "untracked src, unrecorded exotic modes, malformed state (--rebuild-provenance, --rebuild-coupling, --fix).",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

fn tmpAbs(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "provenanceInSync: rebuild only when the compose matches the applied hash" {
    // Same content -> in sync -> rebuild is safe (the legitimate case: an old
    // mox applied this file, and it still composes identically).
    try testing.expect(provenanceInSync(mox.apply.applied.contentHashHex("token = value\n"), "token = value\n"));
    // Source changed since the last apply -> NOT in sync -> must not rebuild,
    // or a removed `<secret:...>`'s cleartext would lose its `.secret` guard.
    try testing.expect(!provenanceInSync(mox.apply.applied.contentHashHex("token = hunter2\n"), "token = PLACEHOLDER\n"));
}

test "findMalformedProvenance: detects an unparseable record" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "state/provenance");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/provenance/deadbeef", .data = "{ not valid json" });

    const state_dir = try tmpAbs(a, io, &tmp, "state");
    const bad = try findMalformedProvenance(a, io, state_dir);
    try testing.expectEqual(@as(usize, 1), bad.len);
}

fn chmod(path: []const u8, mode: u32) void {
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), @intCast(mode));
}

test "unrecordedModes: flags an exotic source mode not in attributes" {
    // The check reads native mode bits; a filesystem without them (Windows)
    // has no exotic mode to lose on clone.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.ssh/config", .data = "Host x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "x\n" });

    const repo = try tmpAbs(a, io, &tmp, "repo");
    const src = try tmpAbs(a, io, &tmp, "repo/src");
    chmod(try tmpAbs(a, io, &tmp, "repo/src/.ssh/config"), 0o600);
    chmod(try tmpAbs(a, io, &tmp, "repo/src/.zshrc"), 0o644);

    // A 0600 source with no attributes record is flagged; the 0644 one is not.
    const flagged = try unrecordedModes(a, io, repo, src);
    try testing.expectEqual(@as(usize, 1), flagged.len);
    try testing.expectEqualStrings(".ssh/config", flagged[0]);

    // Recording the mode clears the advisory.
    var attrs: mox.source.attributes.Attributes = .{
        .arena = a,
        .map = std.StringHashMap(mox.source.attributes.Entry).init(a),
    };
    try attrs.set(".ssh/config", .{ .mode = 0o600 });
    try attrs.write(io, repo);

    const cleared = try unrecordedModes(a, io, repo, src);
    try testing.expectEqual(@as(usize, 0), cleared.len);
}
