const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");
const scope = @import("scope.zig");
const edit = @import("edit.zig");
const tty = @import("tty.zig");
const style = @import("style.zig");
const drift_report = @import("drift_report.zig");
const display = @import("display.zig");

/// One status cell: the label to print and whether it counts against the
/// exit code (the scripting contract: rc 1 when any file needs attention).
const Cell = struct { label: []const u8, problem: bool };

/// Map an apply disposition to its status label. `MISSING`/`OUTDATED`/`DRIFT`
/// each mean `mox apply` would change the file, so all three set the exit
/// code; `clean` does not. `GATED` and `ERROR` are handled by the caller.
fn cellFor(disp: mox.apply.applied.Disposition) Cell {
    return switch (disp) {
        .unchanged => .{ .label = "clean", .problem = false },
        .fresh_write => .{ .label = "MISSING", .problem = true },
        .safe_overwrite => .{ .label = "OUTDATED", .problem = true },
        .drift => .{ .label = "DRIFT", .problem = true },
    };
}

const Spec = struct {
    color: cli.Opt(style.ColorFlag, .{ .default = "auto", .value_name = "color", .help = "auto|always|never" }),
    drift: cli.Flag(.{ .help = "show only the drift set (suppress the clean/gated table)" }),
    json: cli.Flag(.{ .help = "emit the drift set as JSON (implies --drift)" }),
    porcelain: cli.Flag(.{ .help = "emit the drift set as stable tab-separated lines: kind, key, first_contact (0/1), path (implies --drift)" }),
    paths: cli.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    var bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings_map);
    var bindings: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };
    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    var walk_diag: mox.source.tree.Diag = .{};
    const base_tree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, m_state.home, &walk_diag) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox status: source tree not found at {s}\n", .{src_dir});
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
            try ctx.err.print("mox status: ownership declaration: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
            });
            return 1;
        },
        error.UnknownAttributeKey,
        error.InvalidAttributeValue,
        => {
            try ctx.err.print("mox status: attributes.toml: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.source.attributes.diagText(e),
            });
            return 1;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
    const home = m_state.home;

    var files: []const mox.source.tree.ManagedFile = tree.files;
    if (a.paths.len > 0) {
        var diag: scope.Diag = .{};
        files = scope.filterTree(ctx.alloc, ctx.io, tree.files, context.env, context.cwd, a.paths, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox status: {s}: not managed\n", .{diag.capture().?});
                return 1;
            },
            error.OutOfMemory => return e,
            else => |f| return edit.reportTarget(ctx.err, "mox status", diag.capture().?, f),
        };
    }

    // `--drift` and the machine formats suppress the per-file table; the rows
    // still compose (that is how the drift set is found) but write to a discard
    // sink instead of stdout. The drift set below is then rendered (human) or
    // serialized (machine) as the only output.
    const machine = a.json or a.porcelain;
    const show_table = !(a.drift or machine);
    var discard_buf: [64]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
    const rows: *std.Io.Writer = if (show_table) ctx.out else &discarding.writer;

    var problems: usize = 0;
    // Every drifted unit this run finds, classified the same way `mox apply`
    // does (same classifier, `apply/drift.zig`) -- fed to the shared renderer
    // below so the two commands' drift summaries can never disagree.
    var units: std.ArrayList(mox.apply.drift.Unit) = .empty;
    for (files) |file| {
        // Every row names the file the way a human reads it; the real path is
        // still what the checks below are run against.
        const shown = try display.alloc(ctx.alloc, file.live_path, home);
        // A head declaration the walk could not honor is this file's error
        // alone; every other file still reports.
        if (file.head_error.len > 0) {
            try rows.print("  {s:<8} {s} ({s})\n", .{ "ERROR", shown, file.head_error });
            problems += 1;
            continue;
        }
        // A tracked source matching an ignore rule (itself or a containing
        // directory) is never applied, so status has nothing to report for it.
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, file.live_path);
        if (ruleset.isPathIgnored(rel, false)) continue;
        // A GENERATOR: report each file in its current produced set with its
        // own clean/OUTDATED/DRIFT/MISSING state, one line per produced path.
        {
            var gdiag: mox.compose.interp.Diag = .{};
            if (mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &gdiag) catch |e| {
                if (gdiag.capture()) |cap| {
                    try rows.print("  {s:<8} {s} (compose failed: {s}: {s})\n", .{ "ERROR", shown, @errorName(e), cap });
                } else {
                    try rows.print("  {s:<8} {s} (compose failed: {s})\n", .{ "ERROR", shown, @errorName(e) });
                }
                problems += 1;
                continue;
            }) |outputs| {
                // The drift summary scopes a generator to its own row: any
                // one drifted leaf is enough to add it once, regardless of
                // how many leaves under it drifted.
                var gen_drifted = false;
                for (outputs) |o| {
                    const leaf_shown = try display.alloc(ctx.alloc, o.live_path, home);
                    // Kind guard BEFORE the open: a FIFO here would block the
                    // read and brick the whole report.
                    if (mox.apply.write.guardLiveRead(ctx.io, o.live_path) == .special) {
                        try rows.print("  {s:<8} {s}\n", .{ "ERROR", leaf_shown });
                        problems += 1;
                        continue;
                    }
                    const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, o.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
                        error.FileNotFound => null,
                        error.OutOfMemory => return e,
                        else => {
                            try rows.print("  {s:<8} {s}\n", .{ "ERROR", leaf_shown });
                            problems += 1;
                            continue;
                        },
                    };
                    const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, o.live_path);
                    const disp = mox.apply.applied.classify(recorded, live, o.content);
                    if (disp == .drift) gen_drifted = true;
                    const cell = cellFor(disp);
                    if (cell.problem) problems += 1;
                    try rows.print("  {s:<8} {s}\n", .{ cell.label, leaf_shown });
                }
                if (gen_drifted) try units.append(ctx.alloc, mox.apply.drift.generatedSet(file.live_path));
                continue;
            }
        }
        // Seed-once files are user-owned after their first write, so their
        // content is never drift. Report only whether the seed is present.
        if (file.create_once) {
            const present = blk: {
                std.Io.Dir.cwd().access(ctx.io, file.live_path, .{}) catch break :blk false;
                break :blk true;
            };
            if (present) {
                try rows.print("  {s:<8} {s}\n", .{ "clean", shown });
            } else {
                problems += 1;
                try rows.print("  {s:<8} {s}\n", .{ "MISSING", shown });
            }
            continue;
        }
        // A symlink target must be inspected WITHOUT following the link:
        // readFileAlloc would dereference it, reading the pointed-to content
        // (perpetual DRIFT) or aborting on a link to a directory. Mirror
        // apply's symlink classification, read-only.
        if (file.is_symlink) {
            const composed = mox.compose.composeFile(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets) catch {
                try rows.print("  {s:<8} {s}\n", .{ "ERROR", shown });
                problems += 1;
                continue;
            };
            if (composed == null) {
                try rows.print("  {s:<8} {s}\n", .{ "GATED", shown });
                continue;
            }
            const target = std.mem.trim(u8, composed.?, " \t\r\n");
            const site = mox.apply.applied.inspectSymSite(ctx.io, ctx.alloc, file.live_path);
            const recorded_target = try mox.apply.applied.readSymlink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
            const disp = mox.apply.drift.symlinkDisposition(site, recorded_target, target);
            const cell = cellFor(disp);
            if (cell.problem) problems += 1;
            if (mox.apply.drift.symlink(file.live_path, site, recorded_target, target)) |u| try units.append(ctx.alloc, u);
            try rows.print("  {s:<8} {s}\n", .{ cell.label, shown });
            continue;
        }
        // Partial files carry their ownership inventory on every line, so the
        // whole set of partial contracts is visible in one status run.
        const annot = try ownAnnotation(ctx.alloc, file);
        var diag: mox.compose.interp.Diag = .{};
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, null, &diag) catch |e| {
            if (diag.capture()) |cap| {
                try rows.print("  {s:<8} {s}{s} (compose failed: {s}: {s})\n", .{ "ERROR", shown, annot, @errorName(e), cap });
            } else {
                try rows.print("  {s:<8} {s}{s} (compose failed: {s})\n", .{ "ERROR", shown, annot, @errorName(e) });
            }
            problems += 1;
            continue;
        };
        if (composed == null) {
            // Mirror apply's omit handling so status and apply never disagree
            // on an emptied file. A whole file mox wrote whose source now
            // composes to nothing is pending removal (live still matches the
            // record: apply will remove it) or drift (edited since mox wrote
            // it: apply keeps it and reports). A path with no whole-file record
            // (a symlink, an owned file, or one mox never wrote) or an absent
            // live file is simply not here -- GATED, no problem.
            const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
            const live_omit: ?[]const u8 = if (recorded == null or mox.apply.write.guardLiveRead(ctx.io, file.live_path) == .special)
                null
            else
                std.Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch null;
            if (recorded != null and live_omit != null) {
                const live_hash = mox.apply.applied.contentHashHex(live_omit.?);
                problems += 1;
                if (std.mem.eql(u8, &recorded.?, &live_hash)) {
                    try rows.print("  {s:<8} {s}{s}\n", .{ "STALE", shown, annot });
                } else {
                    try units.append(ctx.alloc, mox.apply.drift.vanished(file.live_path));
                    try rows.print("  {s:<8} {s}{s}\n", .{ "DRIFT", shown, annot });
                }
                continue;
            }
            try rows.print("  {s:<8} {s}{s}\n", .{ "GATED", shown, annot });
            continue;
        }

        // A partial file is classified on its owned subtree only;
        // program activity outside the declared paths can never surface.
        if (file.own_paths.len > 0) {
            const cell = try partialCell(ctx, context.paths.state_dir, file, composed.?, &units);
            if (cell.problem) problems += 1;
            try rows.print("  {s:<8} {s}{s}\n", .{ cell.label, shown, annot });
            continue;
        }

        // Kind guard BEFORE the open: a FIFO here would block the read and
        // brick the whole report.
        if (mox.apply.write.guardLiveRead(ctx.io, file.live_path) == .special) {
            try rows.print("  {s:<8} {s}\n", .{ "ERROR", shown });
            problems += 1;
            continue;
        }
        const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => null,
            // An unreadable or oversize live file is one file's problem, not a
            // reason to abort the whole status report.
            error.OutOfMemory => return e,
            else => {
                try rows.print("  {s:<8} {s}\n", .{ "ERROR", shown });
                problems += 1;
                continue;
            },
        };
        const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
        const disp = mox.apply.applied.classify(recorded, live, composed.?);
        const cell = cellFor(disp);
        if (cell.problem) problems += 1;
        if (mox.apply.drift.wholeFile(file.live_path, recorded, live, composed.?)) |u| try units.append(ctx.alloc, u);
        try rows.print("  {s:<8} {s}\n", .{ cell.label, shown });
    }

    // One order for every consumer -- the report and both serializers -- so
    // machine output is stable across runs, OSes, and pipes.
    mox.apply.drift.sortByPath(units.items);

    if (machine) {
        if (a.json) try emitJson(ctx.out, units.items) else try emitPorcelain(ctx.out, units.items);
        return if (problems > 0) 1 else 0;
    }

    const sty = style.Style{ .on = style.enabled(
        tty.isInteractive(1),
        context.env.get(ctx.alloc, "NO_COLOR") != null,
        a.color orelse .auto,
    ) };
    try drift_report.render(ctx.alloc, ctx.out, units.items, .{
        .home = home,
        .sty = sty,
        .width = tty.terminalWidth(80),
    });

    // The probe log and unbound-facts sections are the full-report context, not
    // part of the drift set, so `--drift` omits them.
    if (show_table) {
        try printProbeLog(ctx, m_state);
        try printUnboundFacts(ctx, context.paths.repo_dir, &bindings);
    }
    return if (problems > 0) 1 else 0;
}

/// Emit the drift set as JSON: an array of `{path, kind, [key], first_contact}`.
/// `kind` is a stable tag (`whole_file`, `owned_key`, `symlink_target`,
/// `generated_set`, `vanished`); `key` appears only for `owned_key` (its owned
/// key path, or null for a secret whole-scope record). The schema is locked by
/// test so tooling consumes this instead of parsing the human report.
fn emitJson(out: *std.Io.Writer, units: []const mox.apply.drift.Unit) !void {
    try out.writeByte('[');
    for (units, 0..) |u, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll("{\"path\":");
        try writeJsonString(out, u.path);
        try out.print(",\"kind\":\"{s}\"", .{@tagName(u.kind)});
        switch (u.kind) {
            .owned_key => |k| {
                try out.writeAll(",\"key\":");
                if (k) |key| try writeJsonString(out, key) else try out.writeAll("null");
            },
            else => {},
        }
        try out.writeAll(",\"first_contact\":");
        try out.writeAll(if (u.first_contact) "true" else "false");
        try out.writeByte('}');
    }
    try out.writeAll("]\n");
}

fn writeJsonString(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => if (c < 0x20) try out.print("\\u{x:0>4}", .{c}) else try out.writeByte(c),
    };
    try out.writeByte('"');
}

/// Emit the drift set as stable tab-separated lines, one unit per line:
/// `kind \t key \t first_contact(0|1) \t path`. `key` is empty except for an
/// `owned_key`. The two free-form fields (`key` and `path`) are C-escaped so a
/// literal tab or newline in them can never break the field or line framing:
/// `\` -> `\\`, tab -> `\t`, newline -> `\n`, CR -> `\r`. `kind` and the flag
/// are fixed tokens with no such bytes. Newline-terminated; a dependency-free
/// shell splits on tab and, if it needs exact bytes, unescapes those four.
fn emitPorcelain(out: *std.Io.Writer, units: []const mox.apply.drift.Unit) !void {
    for (units) |u| {
        const key: []const u8 = switch (u.kind) {
            .owned_key => |k| k orelse "",
            else => "",
        };
        try out.print("{s}\t", .{@tagName(u.kind)});
        try writePorcelainField(out, key);
        try out.print("\t{s}\t", .{if (u.first_contact) "1" else "0"});
        try writePorcelainField(out, u.path);
        try out.writeByte('\n');
    }
}

fn writePorcelainField(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try out.writeAll("\\\\"),
        '\t' => try out.writeAll("\\t"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(c),
    };
}

/// This run's `unbound facts:` section: every discovered dimension that is
/// still unbound and currently askable, with a compact provenance, sorted --
/// its own section (not folded into the probe log above), printed only when
/// non-empty. A structural discovery error is not this command's to report:
/// `walkDiag` above already caught and refused on one before this point, so
/// by the time this runs the tree is known to parse.
fn printUnboundFacts(ctx: *app.Ctx, repo_dir: []const u8, bindings: *const mox.dsl.resolver.Resolver) !void {
    const discovery = try mox.machine.dimensions.discover(ctx.alloc, ctx.io, repo_dir);
    const outcome = try mox.machine.interview.walkDimensions(ctx.alloc, discovery.dimensions, bindings, .report_only);
    if (outcome.unbound.len == 0) return;

    try ctx.out.writeAll("\nunbound facts:\n");
    for (outcome.unbound) |name| {
        const dim = findDimByName(discovery.dimensions, name) orelse continue;
        try ctx.out.print("  {s} (", .{name});
        try mox.machine.dimensions.writeProvenance(ctx.out, dim.provenance);
        try ctx.out.writeAll(")\n");
    }
}

fn findDimByName(dims: []const mox.machine.dimensions.Dimension, name: []const u8) ?mox.machine.dimensions.Dimension {
    for (dims) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

/// This run's open-axis probe log: after every file has composed, name
/// the `tool=`/`env=` names this run actually asked and their outcome, so a
/// typo'd gate (`when tool=hedrr`) is one status call from visible instead
/// of a silent false forever. Printed only when at least one probe
/// happened; an axis with zero probes gets no line at all.
fn printProbeLog(ctx: *app.Ctx, m_state: mox.machine.state.MachineState) !void {
    var printed_any = false;
    if (m_state.tool_probe) |tp| {
        printed_any = try printProbedAxis(ctx, "tool", try tp.probedNames(ctx.alloc), printed_any);
    }
    if (m_state.env_probe) |ep| {
        _ = try printProbedAxis(ctx, "env", try ep.probedNames(ctx.alloc), printed_any);
    }
}

/// One probe-log line (`"tool probed: fd present, hedrr ABSENT"`), or
/// nothing when `names` is empty. Returns true once any line -- this call's
/// or an earlier one's -- has printed, so the section's blank-line lead-in
/// prints exactly once regardless of which axis triggers it first.
fn printProbedAxis(ctx: *app.Ctx, axis: []const u8, names: []const mox.machine.path_lookup.ProbedName, already_printed: bool) !bool {
    if (names.len == 0) return already_printed;
    if (!already_printed) try ctx.out.writeAll("\n");
    try ctx.out.print("{s} probed:", .{axis});
    for (names, 0..) |n, i| {
        try ctx.out.writeAll(if (i == 0) " " else ", ");
        try ctx.out.print("{s} {s}", .{ n.name, if (n.present) "present" else "ABSENT" });
    }
    try ctx.out.writeAll("\n");
    return true;
}

/// The ownership annotation appended to a partial file's status line:
/// `  (own N)` / `  (disown N)` with N the declared path count. Empty for a
/// whole-file target, so every other line is unchanged.
fn ownAnnotation(arena: std.mem.Allocator, file: mox.source.tree.ManagedFile) ![]const u8 {
    if (file.own_paths.len == 0) return "";
    const word: []const u8 = if (file.ownership == .disown) "disown" else "own";
    return std.fmt.allocPrint(arena, "  ({s} {d})", .{ word, file.own_paths.len });
}

/// The status cell for one partial file: MISSING only when the live
/// file is absent; otherwise the extracted live owned subtree is compared
/// canonically against the owned record (DRIFT) and the composed owned
/// document (OUTDATED), clean when all equal. A composed document violating
/// its declaration, or an unparseable composed/live file, is ERROR --
/// the same shapes apply refuses.
fn partialCell(ctx: *app.Ctx, state_dir: []const u8, file: mox.source.tree.ManagedFile, composed: []const u8, units: *std.ArrayList(mox.apply.drift.Unit)) !Cell {
    const partial_mod = mox.apply.partial;
    const owned_mod = mox.apply.owned;
    const err_cell: Cell = .{ .label = "ERROR", .problem = true };
    // The walk only attaches own_paths to structured targets.
    const format = mox.source.format.formatOfPath(file.source_base_path).?;

    const mode: mox.apply.applied.Mode = if (file.ownership == .disown) .disown else .own;
    const owned = partial_mod.OwnedDoc.parse(ctx.alloc, format, composed) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => return err_cell,
    };
    switch (mode) {
        .own => if (try partial_mod.undeclaredLeaf(ctx.alloc, &owned, file.own_paths) != null) return err_cell,
        .disown => if (try partial_mod.populatedDisownPath(ctx.alloc, &owned, file.own_paths) != null) return err_cell,
    }

    // Read through a symlinked live path exactly as apply patches it: via the
    // resolved target. A dangling link is the shape apply refuses, so ERROR,
    // never MISSING (apply would not create it).
    const live_target = mox.apply.write.resolvePartialLive(ctx.alloc, ctx.io, file.live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => return err_cell,
    };
    // Kind guard BEFORE the open: a FIFO here would block the read and brick
    // the whole report.
    if (mox.apply.write.guardLiveRead(ctx.io, live_target) == .special) return err_cell;
    const live: []const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, live_target, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return cellFor(.fresh_write),
        error.OutOfMemory => return e,
        else => return err_cell,
    };
    const live_doc = partial_mod.OwnedDoc.parse(ctx.alloc, format, live) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => return err_cell,
    };

    const record = try mox.apply.applied.readOwned(ctx.alloc, ctx.io, state_dir, file.live_path);
    const record_paths: []const mox.source.tree.OwnPath = if (record) |r| try owned_mod.parseRawPaths(ctx.alloc, r.own_paths) else &.{};
    const class = try owned_mod.classifyMode(ctx.alloc, mode, &owned, &live_doc, file.own_paths, record, record_paths);
    if (mox.apply.drift.ownedFile(file.live_path, class, record)) |u| try units.append(ctx.alloc, u);
    return switch (class) {
        .clean => cellFor(.unchanged),
        .outdated => cellFor(.safe_overwrite),
        .drift => cellFor(.drift),
    };
}

pub const command = app.command(Spec, .{
    .name = "status",
    .summary = "Show managed files with their state",
    .details = "Labels clean, OUTDATED, DRIFT, MISSING, STALE, GATED, ERROR. Exit 1 if any file is OUTDATED, DRIFT, MISSING, STALE, or ERROR. --drift shows only the drift set; --json / --porcelain serialize it for tooling (both imply --drift).",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "cellFor: dispositions map to labels and problem flags" {
    try testing.expectEqualStrings("clean", cellFor(.unchanged).label);
    try testing.expect(!cellFor(.unchanged).problem);

    try testing.expectEqualStrings("MISSING", cellFor(.fresh_write).label);
    try testing.expect(cellFor(.fresh_write).problem);

    try testing.expectEqualStrings("OUTDATED", cellFor(.safe_overwrite).label);
    try testing.expect(cellFor(.safe_overwrite).problem);

    try testing.expectEqualStrings("DRIFT", cellFor(.drift).label);
    try testing.expect(cellFor(.drift).problem);
}

test "ownAnnotation: own and disown counts, empty for whole-file targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_]mox.source.tree.OwnPath{
        .{ .raw = "tui", .segments = &.{"tui"} },
        .{ .raw = "model", .segments = &.{"model"} },
    };

    var file: mox.source.tree.ManagedFile = .{
        .source_base_path = "src/app.toml",
        .source_base_abs = "",
        .live_path = "",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
    };
    try testing.expectEqualStrings("", try ownAnnotation(a, file));

    file.ownership = .own;
    file.own_paths = paths[0..2];
    try testing.expectEqualStrings("  (own 2)", try ownAnnotation(a, file));

    file.ownership = .disown;
    file.own_paths = paths[0..1];
    try testing.expectEqualStrings("  (disown 1)", try ownAnnotation(a, file));
}

test "emitPorcelain / emitJson: tab, newline, and backslash in a field cannot break the format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // A path with a literal tab, newline, and backslash, and an owned key with
    // a tab (a TOML key legally can): both are free-form fields.
    const units = [_]mox.apply.drift.Unit{
        .{ .path = "/h/a\tb\nc\\d", .kind = .{ .owned_key = "k\tey" }, .first_contact = false },
        .{ .path = "/h/plain", .kind = .whole_file, .first_contact = true },
    };

    // Porcelain: each unit stays one line; the tab/newline/backslash in key and
    // path are C-escaped, so a tab-split parser still sees exactly four fields.
    var pw: std.Io.Writer.Allocating = .init(al);
    try emitPorcelain(&pw.writer, &units);
    try testing.expectEqualStrings(
        "owned_key\tk\\tey\t0\t/h/a\\tb\\nc\\\\d\n" ++
            "whole_file\t\t1\t/h/plain\n",
        pw.written(),
    );

    // JSON: the same bytes escaped per the JSON string grammar.
    var jw: std.Io.Writer.Allocating = .init(al);
    try emitJson(&jw.writer, &units);
    try testing.expectEqualStrings(
        "[{\"path\":\"/h/a\\tb\\nc\\\\d\",\"kind\":\"owned_key\",\"key\":\"k\\tey\",\"first_contact\":false}," ++
            "{\"path\":\"/h/plain\",\"kind\":\"whole_file\",\"first_contact\":true}]\n",
        jw.written(),
    );
}
