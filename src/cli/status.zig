const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");
const scope = @import("scope.zig");

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
    paths: cli.spec.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

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
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
    const home = m_state.home;

    var files: []const mox.source.tree.ManagedFile = tree.files;
    if (a.paths.len > 0) {
        var diag: scope.Diag = .{};
        files = scope.filterTree(ctx.alloc, ctx.io, tree.files, home, a.paths, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox status: {s}: not managed\n", .{diag.capture().?});
                return 1;
            },
            else => return e,
        };
    }

    var problems: usize = 0;
    for (files) |file| {
        // A head declaration the walk could not honor is this file's error
        // alone; every other file still reports.
        if (file.head_error.len > 0) {
            try ctx.out.print("  {s:<8} {s} ({s})\n", .{ "ERROR", file.live_path, file.head_error });
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
            if (mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &gdiag) catch {
                try ctx.out.print("  {s:<8} {s}\n", .{ "ERROR", file.live_path });
                problems += 1;
                continue;
            }) |outputs| {
                for (outputs) |o| {
                    const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, o.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
                        error.FileNotFound => null,
                        error.OutOfMemory => return e,
                        else => {
                            try ctx.out.print("  {s:<8} {s}\n", .{ "ERROR", o.live_path });
                            problems += 1;
                            continue;
                        },
                    };
                    const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, o.live_path);
                    const cell = cellFor(mox.apply.applied.classify(recorded, live, o.content));
                    if (cell.problem) problems += 1;
                    try ctx.out.print("  {s:<8} {s}\n", .{ cell.label, o.live_path });
                }
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
                try ctx.out.print("  {s:<8} {s}\n", .{ "clean", file.live_path });
            } else {
                problems += 1;
                try ctx.out.print("  {s:<8} {s}\n", .{ "MISSING", file.live_path });
            }
            continue;
        }
        // A symlink target must be inspected WITHOUT following the link:
        // readFileAlloc would dereference it, reading the pointed-to content
        // (perpetual DRIFT) or aborting on a link to a directory. Mirror
        // apply's symlink classification, read-only.
        if (file.is_symlink) {
            const composed = mox.compose.composeFile(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets) catch {
                try ctx.out.print("  {s:<8} {s}\n", .{ "ERROR", file.live_path });
                problems += 1;
                continue;
            };
            if (composed == null) {
                try ctx.out.print("  {s:<8} {s}\n", .{ "GATED", file.live_path });
                continue;
            }
            const target = std.mem.trim(u8, composed.?, " \t\r\n");
            const site = mox.apply.applied.inspectSymSite(ctx.io, ctx.alloc, file.live_path);
            const recorded_target = try mox.apply.applied.readSymlink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
            const disp: mox.apply.applied.Disposition = switch (site) {
                .absent => .fresh_write,
                .symlink => |cur| blk: {
                    if (mox.apply.applied.sameSymlinkTarget(cur, target)) break :blk .unchanged;
                    if (recorded_target) |rt| if (mox.apply.applied.sameSymlinkTarget(rt, cur)) break :blk .safe_overwrite;
                    break :blk .drift;
                },
                // A regular file, directory, or special entry where a symlink
                // is expected: mox never records a non-symlink here, so drift.
                .directory, .other => .drift,
            };
            const cell = cellFor(disp);
            if (cell.problem) problems += 1;
            try ctx.out.print("  {s:<8} {s}\n", .{ cell.label, file.live_path });
            continue;
        }
        // Partial files carry their ownership inventory on every line, so the
        // whole set of partial contracts is visible in one status run.
        const annot = try ownAnnotation(ctx.alloc, file);
        const composed = mox.compose.composeFile(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets) catch {
            try ctx.out.print("  {s:<8} {s}{s}\n", .{ "ERROR", file.live_path, annot });
            problems += 1;
            continue;
        };
        if (composed == null) {
            try ctx.out.print("  {s:<8} {s}{s}\n", .{ "GATED", file.live_path, annot });
            continue;
        }

        // A partial file is classified on its owned subtree only (D6);
        // program activity outside the declared paths can never surface.
        if (file.own_paths.len > 0) {
            const cell = try partialCell(ctx, context.paths.state_dir, file, composed.?);
            if (cell.problem) problems += 1;
            try ctx.out.print("  {s:<8} {s}{s}\n", .{ cell.label, file.live_path, annot });
            continue;
        }

        const live: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => null,
            // An unreadable or oversize live file is one file's problem, not a
            // reason to abort the whole status report.
            error.OutOfMemory => return e,
            else => {
                try ctx.out.print("  {s:<8} {s}\n", .{ "ERROR", file.live_path });
                problems += 1;
                continue;
            },
        };
        const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
        const disp = mox.apply.applied.classify(recorded, live, composed.?);
        const cell = cellFor(disp);
        if (cell.problem) problems += 1;
        try ctx.out.print("  {s:<8} {s}\n", .{ cell.label, file.live_path });
    }
    return if (problems > 0) 1 else 0;
}

/// The ownership annotation appended to a partial file's status line:
/// `  (own N)` / `  (disown N)` with N the declared path count. Empty for a
/// whole-file target, so every other line is unchanged.
fn ownAnnotation(arena: std.mem.Allocator, file: mox.source.tree.ManagedFile) ![]const u8 {
    if (file.own_paths.len == 0) return "";
    const word: []const u8 = if (file.ownership == .disown) "disown" else "own";
    return std.fmt.allocPrint(arena, "  ({s} {d})", .{ word, file.own_paths.len });
}

/// The status cell for one partial file, per D6: MISSING only when the live
/// file is absent; otherwise the extracted live owned subtree is compared
/// canonically against the owned record (DRIFT) and the composed owned
/// document (OUTDATED), clean when all equal. A composed document violating
/// its declaration (D2), or an unparseable composed/live file, is ERROR --
/// the same shapes apply refuses.
fn partialCell(ctx: *app.Ctx, state_dir: []const u8, file: mox.source.tree.ManagedFile, composed: []const u8) !Cell {
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
    return switch (try owned_mod.classifyMode(ctx.alloc, mode, &owned, &live_doc, file.own_paths, record, record_paths)) {
        .clean => cellFor(.unchanged),
        .outdated => cellFor(.safe_overwrite),
        .drift => cellFor(.drift),
    };
}

pub const command = app.command(Spec, .{
    .name = "status",
    .summary = "Show managed files with their state",
    .details = "Labels clean, OUTDATED, DRIFT, MISSING, GATED, ERROR. Exit 1 if any file is OUTDATED, DRIFT, MISSING, or ERROR.",
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
