const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

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

const Spec = struct {};

fn run(ctx: *app.Ctx, _: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox status: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir);
    const home = m_state.home;

    var problems: usize = 0;
    for (tree.files) |file| {
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
        const composed = mox.compose.composeFile(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets) catch {
            try ctx.out.print("  {s:<8} {s}\n", .{ "ERROR", file.live_path });
            problems += 1;
            continue;
        };
        if (composed == null) {
            try ctx.out.print("  {s:<8} {s}\n", .{ "GATED", file.live_path });
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
