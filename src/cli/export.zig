//! `mox export --resolved [--as <tuple>] <out>`: bake a flat resolved tree.
//!
//! Every managed file is composed for the current machine (or the axis tuple
//! given by `--as`) and written under `<out>/<live-rel>`, where `<live-rel>`
//! is the file's live path relative to HOME. This is the walk-away guarantee
//! and the CI parity harness input. Read-only wrt mox state: no lock, no
//! applied/provenance records touched.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Io = std.Io;
const AxisTuple = mox.source.tree.AxisTuple;

/// Live path relative to `home`, or null when `live_path` is not under `home`.
pub fn liveRel(arena: std.mem.Allocator, home: []const u8, live_path: []const u8) !?[]const u8 {
    return mox.source.path.liveKeyUnderHome(arena, home, live_path);
}

/// Destination path for a composed file inside the export tree:
/// `<out>/<live-rel>`. Null when `live_path` is not under `home`.
pub fn exportDest(arena: std.mem.Allocator, out_dir: []const u8, home: []const u8, live_path: []const u8) !?[]const u8 {
    const rel = (try liveRel(arena, home, live_path)) orelse return null;
    return try mox.source.path.joinKeyOnto(arena, out_dir, rel);
}

/// Override `bindings` from an `--as` tuple. Each pair is applied both as a
/// single-value axis (`os` -> `darwin`) and as a set-membership key
/// (`os=darwin` -> `1`), so either axis style resolves against it.
pub fn applyTupleOverride(arena: std.mem.Allocator, bindings: *std.StringHashMap([]const u8), tuple: AxisTuple) !void {
    for (tuple.pairs) |p| {
        try bindings.put(p.name, p.value);
        const member = try std.fmt.allocPrint(arena, "{s}={s}", .{ p.name, p.value });
        try bindings.put(member, "1");
    }
}

const Spec = struct {
    resolved: cli.spec.Flag(.{ .help = "required: bake resolved output" }),
    as: cli.spec.Opt([]const u8, .{ .value_name = "tuple", .help = "compose as if bound to this axis tuple" }),
    out: cli.spec.Pos([]const u8, .{ .help = "output directory" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    if (!a.resolved) {
        try ctx.err.writeAll("mox export: usage: mox export --resolved [--as <tuple>] <out-dir>\n");
        return 2;
    }
    const out_dir = a.out;

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    if (a.as) |as| {
        const tuple = mox.source.tuple.parseFilename(ctx.alloc, as) catch {
            try ctx.err.print("mox export: invalid axis tuple '{s}'\n", .{as});
            return 2;
        };
        try applyTupleOverride(ctx.alloc, &bindings, tuple);
    }

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox export: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    var written: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    for (tree.files) |file| {
        // A GENERATOR renders one file per row, statelessly (export never
        // deletes, so a row dropped since a prior apply simply is not written).
        {
            var gdiag: mox.compose.interp.Diag = .{};
            const gen = mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &gdiag) catch |e| {
                try ctx.err.print("mox export: {s}: generator failed: {s}\n", .{ file.live_path, @errorName(e) });
                if (gdiag.capture()) |cap|
                    try ctx.err.print("mox export:   failing item: {s}\n", .{cap});
                failed += 1;
                continue;
            };
            if (gen) |outputs| {
                for (outputs) |o| {
                    const dest = (try exportDest(ctx.alloc, out_dir, m_state.home, o.live_path)) orelse {
                        try ctx.err.print("mox export: {s}: outside HOME, cannot place in export tree\n", .{o.live_path});
                        failed += 1;
                        continue;
                    };
                    const eff_mode = mox.apply.write.secretRestrictedMode(o.manager_secret, false, 0o644, null);
                    if (o.manager_secret)
                        try ctx.err.print("mox export: {s}: baked a resolved op/pass secret (cleartext) at 0600\n", .{dest});
                    mox.apply.write.writeAtomic(ctx.io, dest, o.content, eff_mode) catch |e| {
                        try ctx.err.print("mox export: {s}: write failed: {s}\n", .{ dest, @errorName(e) });
                        failed += 1;
                        continue;
                    };
                    written += 1;
                }
                continue;
            }
        }

        var diag: mox.compose.interp.Diag = .{};
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, null, &diag) catch |e| {
            try ctx.err.print("mox export: {s}: compose failed: {s}\n", .{ file.live_path, @errorName(e) });
            if (diag.capture()) |cap|
                try ctx.err.print("mox export:   failing item: {s}\n", .{cap});
            failed += 1;
            continue;
        };
        const bytes = composed orelse {
            skipped += 1;
            continue;
        };

        const dest = (try exportDest(ctx.alloc, out_dir, m_state.home, file.live_path)) orelse {
            try ctx.err.print("mox export: {s}: outside HOME, cannot place in export tree\n", .{file.live_path});
            failed += 1;
            continue;
        };

        if (file.is_symlink) {
            const target = std.mem.trim(u8, bytes, " \t\r\n");
            if (std.fs.path.dirname(dest)) |parent| Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
            Io.Dir.cwd().deleteFile(ctx.io, dest) catch {};
            Io.Dir.cwd().symLink(ctx.io, target, dest, .{}) catch |e| {
                try ctx.err.print("mox export: {s}: symlink failed: {s}\n", .{ dest, @errorName(e) });
                failed += 1;
                continue;
            };
        } else {
            // A baked op/pass secret lands at 0600 here too (the export tree
            // holds resolved cleartext), and is announced so pointing export at
            // a committed/CI dir does not silently ship a secret.
            // The export tree is written fresh, so there is no prior mode to
            // respect: a manager secret lands at exactly 0600.
            const eff_mode = mox.apply.write.secretRestrictedMode(diag.manager_secret, file.mode_explicit, file.mode, null);
            if (diag.manager_secret) {
                try ctx.err.print("mox export: {s}: baked a resolved op/pass secret (cleartext) at 0600\n", .{dest});
            }
            mox.apply.write.writeAtomic(ctx.io, dest, bytes, eff_mode) catch |e| {
                try ctx.err.print("mox export: {s}: write failed: {s}\n", .{ dest, @errorName(e) });
                failed += 1;
                continue;
            };
        }
        written += 1;
    }

    try ctx.out.print("Exported {d} file(s) to {s} ({d} gated off, {d} failed)\n", .{ written, out_dir, skipped, failed });
    return if (failed > 0) 1 else 0;
}

pub const command = app.command(Spec, .{
    .name = "export",
    .summary = "Bake a flat resolved tree into a dir",
    .usage = "mox export --resolved [--as <tuple>] <out>",
    .details = "Composes every file under <out>/<rel>.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "liveRel: strips the home prefix as a key, rejects paths outside home" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(".zshrc", (try liveRel(a, "/home/me", "/home/me/.zshrc")).?);
    try testing.expectEqualStrings(".config/git/config", (try liveRel(a, "/home/me/", "/home/me/.config/git/config")).?);
    try testing.expect((try liveRel(a, "/home/me", "/etc/passwd")) == null);
}

test "exportDest: joins out dir with the home-relative path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dest = (try exportDest(a, "/out", "/home/me", "/home/me/.config/nvim/init.lua")).?;
    // The export tree is a real filesystem tree, so its paths are native.
    const want = try std.fs.path.join(a, &.{ "/out", ".config", "nvim", "init.lua" });
    try testing.expectEqualStrings(want, dest);
    try testing.expect(try exportDest(a, "/out", "/home/me", "/tmp/x") == null);
}

test "applyTupleOverride: sets both single-value and membership bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "linux");
    const tuple = try mox.source.tuple.parseFilename(a, "os=darwin");
    try applyTupleOverride(a, &bindings, tuple);
    try testing.expectEqualStrings("darwin", bindings.get("os").?);
    try testing.expectEqualStrings("1", bindings.get("os=darwin").?);
}
