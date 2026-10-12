//! `mox diff`: show, per managed file, a unified diff of the composed output
//! against the current live file. Read-only: takes no lock and writes nothing.
//! `--stat` prints a one-line added/removed summary per file instead of the
//! full hunks. A difference is not an error (exit 0); a refusal exits 1.

const std = @import("std");
const cli = @import("cli");
const apply_cmd = @import("apply.zig");
const app = @import("app.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");
const style = @import("style.zig");
const tty = @import("tty.zig");
const status_mod = @import("status.zig");
const scope = @import("scope.zig");
const edit = @import("edit.zig");

const Io = std.Io;
const Hunk = mox.diff.lines.Hunk;

const max_file_bytes: usize = 64 * 1024 * 1024;

/// Added/removed line counts for one file's diff.
pub const Stat = struct {
    added: usize = 0,
    removed: usize = 0,
};

/// Sum the added (`+`, from composed) and removed (`-`, from live) line counts
/// across every hunk. `a` is the live side, `b` the composed side.
pub fn statOf(hunks: []const Hunk) Stat {
    var s: Stat = .{};
    for (hunks) |h| {
        s.removed += h.a_len;
        s.added += h.b_len;
    }
    return s;
}

/// Render a unified diff for one file. `a_lines` is the live content, `b_lines`
/// the composed content, `hunks` the edit script turning live into composed.
/// `a_secret` / `b_secret` mark, per line, whether that line's provenance is a
/// resolved secret: any hunk touching a secret line has BOTH its sides redacted
/// to `secret_redaction`, so `mox diff` never prints a resolved secret value.
/// An empty mask means no secret info for that side (nothing redacted).
/// Returns arena-owned bytes; an empty string when there are no hunks.
pub fn renderFile(
    arena: std.mem.Allocator,
    label: []const u8,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunks: []const Hunk,
    a_secret: []const bool,
    b_secret: []const bool,
    sty: style.Style,
) ![]u8 {
    return renderImpl(arena, label, a_lines, b_lines, hunks, a_secret, b_secret, sty, false);
}

/// `renderFile` for canonical owned blobs: a hunk that does not itself start
/// at a `= <path>` section header is preceded by the header of the section
/// it falls in, printed as a context line, so a scalar-value hunk names its
/// key path. Owned blobs arrive pre-masked, so no per-line secret info applies.
pub fn renderOwnedFile(
    arena: std.mem.Allocator,
    label: []const u8,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunks: []const Hunk,
    sty: style.Style,
) ![]u8 {
    const none: []const bool = &.{};
    return renderImpl(arena, label, a_lines, b_lines, hunks, none, none, sty, true);
}

fn renderImpl(
    arena: std.mem.Allocator,
    label: []const u8,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunks: []const Hunk,
    a_secret: []const bool,
    b_secret: []const bool,
    sty: style.Style,
    section_context: bool,
) ![]u8 {
    if (hunks.len == 0) return "";
    const redaction = mox.provenance.map.secret_redaction;
    var aw: Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;
    try sty.dim(out);
    try out.print("--- {s} (live)\n", .{label});
    try out.print("+++ {s} (composed)\n", .{label});
    try sty.close(out);
    for (hunks) |h| {
        try sty.dim(out);
        try out.print("@@ -{d},{d} +{d},{d} @@\n", .{ h.a_start + 1, h.a_len, h.b_start + 1, h.b_len });
        try sty.close(out);
        if (section_context) {
            if (sectionContextOf(a_lines, b_lines, h)) |header| {
                try sty.dim(out);
                try out.print(" {s}\n", .{header});
                try sty.close(out);
            }
        }
        // Redact the whole hunk when a secret line sits on either side: the two
        // sides of a rotated/removed secret pair up here, and over-redacting a
        // mixed hunk in the DISPLAY is safe where leaking a value is not.
        const secret = hunkTouchesSecret(h, a_secret, b_secret);
        var i: u32 = 0;
        while (i < h.a_len) : (i += 1) {
            const line = if (secret) redaction else a_lines[h.a_start + i];
            try sty.red(out);
            try out.print("-{s}\n", .{line});
            try sty.close(out);
        }
        i = 0;
        while (i < h.b_len) : (i += 1) {
            const line = if (secret) redaction else b_lines[h.b_start + i];
            try sty.green(out);
            try out.print("+{s}\n", .{line});
            try sty.close(out);
        }
    }
    return aw.toOwnedSlice();
}

/// The `= <path>` header of the section the hunk's first displayed line
/// falls in, or null when the hunk itself starts at a header line (the
/// context would only repeat it).
fn sectionContextOf(a_lines: []const []const u8, b_lines: []const []const u8, h: Hunk) ?[]const u8 {
    const first: []const u8 = if (h.b_len > 0)
        b_lines[h.b_start]
    else if (h.a_len > 0)
        a_lines[h.a_start]
    else
        return null;
    if (std.mem.startsWith(u8, first, "= ")) return null;
    if (h.b_len > 0) {
        if (headerBefore(b_lines, h.b_start)) |hd| return hd;
    }
    if (h.a_len > 0) {
        if (headerBefore(a_lines, h.a_start)) |hd| return hd;
    }
    return null;
}

fn headerBefore(lines: []const []const u8, start: usize) ?[]const u8 {
    var i = start;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, lines[i], "= ")) return lines[i];
    }
    return null;
}

/// A hunk touches a secret when any live-side line (per persisted provenance) or
/// composed-side line (per fresh provenance) in its range is a resolved secret.
fn hunkTouchesSecret(h: Hunk, a_secret: []const bool, b_secret: []const bool) bool {
    var i: u32 = 0;
    while (i < h.a_len) : (i += 1) {
        const idx = h.a_start + i;
        if (idx < a_secret.len and a_secret[idx]) return true;
    }
    i = 0;
    while (i < h.b_len) : (i += 1) {
        const idx = h.b_start + i;
        if (idx < b_secret.len and b_secret[idx]) return true;
    }
    return false;
}

/// Build a per-line secret mask of length `count` from provenance `segments`:
/// `mask[i]` is true when output line `i` is covered by a `.secret` segment.
pub fn secretMask(arena: std.mem.Allocator, count: usize, segments: []const mox.provenance.map.Segment) ![]const bool {
    const mask = try arena.alloc(bool, count);
    @memset(mask, false);
    for (segments) |s| {
        if (s.origin != .secret) continue;
        var i: u32 = s.out_start;
        while (i < s.out_start + s.out_len and i < count) : (i += 1) mask[i] = true;
    }
    return mask;
}

const Spec = struct {
    stat: cli.Flag(.{ .help = "per-file added/removed summary instead of full hunks" }),
    color: cli.Opt(style.ColorFlag, .{ .default = "auto", .value_name = "color", .help = "auto|always|never" }),
    paths: cli.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (try apply_cmd.attributesFailure(ctx, "mox diff")) return 2;
    if (try apply_cmd.privateRefusal(ctx, "mox diff")) return 2;
    const context = ctx.context.?;
    const stat_mode = a.stat;
    const sty = style.Style{ .on = style.enabled(
        tty.isInteractive(1),
        context.env.get(ctx.alloc, "NO_COLOR") != null,
        a.color orelse .auto,
    ) };

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
            try ctx.err.print("mox diff: source tree not found at {s}\n", .{src_dir});
            return 0;
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
            try ctx.err.print("mox diff: ownership declaration: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
            });
            return 1;
        },
        error.TomlParseError,
        => {
            try ctx.err.print("mox diff: {s}\n", .{try mox.source.attributes.parseFailure(ctx.alloc, ctx.io, context.paths.repo_dir)});
            return 2;
        },
        else => return e,
    };
    const tree = (try apply_cmd.mergePrivate(ctx, "mox diff", base_tree)) orelse return 2;

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
    const home = m_state.home;

    var files: []const mox.source.tree.ManagedFile = tree.files;
    if (a.paths.len > 0) {
        var diag: scope.Diag = .{};
        files = scope.filterTree(ctx.alloc, ctx.io, tree.files, home, context.cwd, a.paths, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox diff: {s}: not managed\n", .{diag.capture().?});
                if (diag.captureResolved()) |r|
                    try ctx.err.print("mox diff:   looked for {f}\n", .{display.of(r, home)});
                return 1;
            },
            error.OutOfMemory => return e,
            else => |f| return edit.reportTarget(ctx.err, "mox diff", diag.capture().?, f),
        };
    }

    var total: Stat = .{};
    var changed: usize = 0;
    // A malformed attributes entry is a refusal: exit 1 once the rest has
    // diffed.
    var refused = false;

    if (a.paths.len == 0) for (tree.entry_errors) |e| {
        try ctx.err.print("  ERROR   {f} ({s})\n", .{ display.of(e.live_path, home), e.err });
        refused = true;
    };
    var scan: mox.apply.generated.OrphanScan = .init(ctx.alloc);
    var dropped: std.ArrayList(status_mod.Dropped) = .empty;
    for (files) |file| {
        // A head declaration the walk could not honor is this file's error
        // alone; every other file still diffs.
        if (file.head_error.len > 0) {
            try scan.walked(ctx.alloc, file.live_path);
            try ctx.err.print("  ERROR   {f} ({s})\n", .{ display.of(file.live_path, ctx.context.?.paths.home), file.head_error });
            if (file.head_error_attrs) refused = true;
            continue;
        }
        var gdiag: mox.compose.interp.Diag = .{};
        const gen_out = mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &gdiag);
        try apply_cmd.scanGenerator(ctx, &scan, &ruleset, file.live_path, gen_out);
        // A tracked source matching an ignore rule (itself or a containing
        // directory) is never applied, so diff has nothing to compare it against.
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, file.live_path);
        if (ruleset.isPathIgnored(rel, false)) continue;
        // Seed-once and symlink files carry no line-level composed content to
        // diff (user-owned after first write / target-only respectively).
        if (file.create_once or file.is_symlink) continue;

        // A GENERATOR produces N files at rendered paths and never materializes
        // its own; composing it as an ordinary file rejects its own `into`
        // clause. Diff what it produces -- the same set status reports and
        // apply writes -- rather than erroring on the generator itself.
        {
            if (gen_out catch |e| {
                try ctx.err.print("mox diff: {f}: compose failed: {s}\n", .{ display.of(file.live_path, ctx.context.?.paths.home), @errorName(e) });
                if (gdiag.capture()) |cap|
                    try ctx.err.print("mox diff:   failing item: {s}\n", .{cap});
                continue;
            }) |outputs| {
                for (outputs) |o| {
                    if (o.invalid) |why| {
                        try ctx.err.print("  ERROR   {f} ({s})\n", .{ display.of(o.live_path, home), why });
                        continue;
                    }
                    if (try mox.apply.removable.plantedLink(ctx.alloc, ctx.io, context.paths.state_dir, home, o.live_path)) |v| if (v == .remove) {
                        try diffLinkReplace(ctx, sty, stat_mode, o.live_path, v.remove.link, o.content, o.prov, &total, &changed);
                        continue;
                    };
                    try diffOne(ctx, context.paths.state_dir, sty, stat_mode, o.live_path, o.content, o.prov, &total, &changed);
                }
                try status_mod.noteDropped(ctx, &dropped, file.live_path, outputs);
                continue;
            }
        }

        // Track provenance so secret-covered lines can be redacted from the
        // printed diff: the resolved secret is inlined into the composed bytes,
        // and must never reach stdout.
        var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
        var diag: mox.compose.interp.Diag = .{};
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &prov, &diag) catch |e| {
            if (e == error.FormatViolation) {
                const rep_ = mox.compose.validate.splitReport(diag.capture() orelse "?");
                try ctx.err.print("  ERROR   {f} ({s})\n", .{ display.of(file.live_path, ctx.context.?.paths.home), rep_.head });
                try mox.compose.validate.writeMore(ctx.err, rep_.more);
                continue;
            }
            try ctx.err.print("mox diff: {f}: compose failed: {s}\n", .{ display.of(file.live_path, ctx.context.?.paths.home), @errorName(e) });
            if (diag.capture()) |cap|
                try ctx.err.print("mox diff:   failing item: {s}\n", .{cap});
            continue;
        };
        // Composes to nothing on this machine. If mox wrote a whole file here,
        // apply would remove it: show the live content on the removed side. A
        // path mox never wrote (no record) or an already-absent file is not
        // mox's to remove -- nothing to diff.
        const composed_bytes = composed orelse {
            if (file.own_paths.len == 0) {
                const rec = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
                if (rec != null) try diffOne(ctx, context.paths.state_dir, sty, stat_mode, file.live_path, "", &.{}, &total, &changed);
            }
            continue;
        };

        // A planted link rollback put back: --overwrite replaces it.
        if (try mox.apply.applied.rolledBackLink(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path)) |target| {
            try diffLinkReplace(ctx, sty, stat_mode, file.live_path, target, composed_bytes, prov.items, &total, &changed);
            continue;
        }

        // A symlink mox planted where a file now belongs: apply replaces the
        // link with the composed file.
        if (try mox.apply.removable.plantedLink(ctx.alloc, ctx.io, context.paths.state_dir, home, file.live_path)) |v| switch (v) {
            .remove => |found| {
                try diffLinkReplace(ctx, sty, stat_mode, file.live_path, found.link, composed_bytes, prov.items, &total, &changed);
                continue;
            },
            .linked_parent => {
                try ctx.err.print("mox diff: {f}: {s}\n", .{ display.of(file.live_path, home), mox.apply.parent_link.reason });
                continue;
            },
            else => {},
        };

        // A partial file diffs its owned subtree only: canonical composed-owned
        // vs canonical live-owned, as text, labeled with the live path.
        if (file.own_paths.len > 0) {
            try diffPartial(ctx, context.paths.state_dir, sty, stat_mode, file, composed_bytes, prov.items, &total, &changed);
            continue;
        }

        try diffOne(ctx, context.paths.state_dir, sty, stat_mode, file.live_path, composed_bytes, prov.items, &total, &changed);
    }

    // A file whose source left the tree: apply removes it when unedited, so
    // its live content shows on the removed side.
    if (a.paths.len == 0) {
        const stale = mox.apply.stale;
        const repo_tag = try mox.apply.applied.repoTag(ctx.alloc, ctx.io, context.paths.repo_dir, context.paths.home);
        const cands = try stale.candidatesOf(ctx.alloc, ctx.io, context.paths.state_dir, repo_tag, home, tree);
        var live_paths: std.ArrayList([]const u8) = .empty;
        for (tree.files) |f| try live_paths.append(ctx.alloc, f.live_path);
        var inodes = try stale.inodesOf(ctx.alloc, ctx.io, live_paths.items);
        const links = try stale.managedLinks(ctx.alloc, tree.files);
        const jc: mox.apply.removable.Ctx = .{ .home = home, .keep = &scan.keep, .kept = &inodes, .ruleset = &ruleset, .links = &links };
        for (cands) |c| {
            if (try mox.apply.removable.judge(ctx.alloc, ctx.io, jc, c.live_path, mox.apply.removable.wroteOf(c)) != .remove) continue;
            if (c.kind == .symlink) {
                try diffLinkRemoval(ctx, sty, stat_mode, c.live_path, c.target, &total, &changed);
            } else try diffOne(ctx, context.paths.state_dir, sty, stat_mode, c.live_path, "", &.{}, &total, &changed);
        }
        // A file a live generator no longer produces, which apply would prune.
        for (try status_mod.judgeDropped(ctx, tree, &ruleset, &scan, dropped.items)) |j| {
            if (j.verdict != .remove) continue;
            try diffOne(ctx, context.paths.state_dir, sty, stat_mode, j.drop.leaf, "", &.{}, &total, &changed);
        }
        // A file of a generator that left the tree, which apply would remove.
        for (try status_mod.orphanPlan(ctx, tree, &ruleset, &scan)) |m| {
            if (m.released) continue;
            for (m.leaves) |leaf| {
                if (leaf.verdict != .remove) continue;
                try diffOne(ctx, context.paths.state_dir, sty, stat_mode, leaf.path, "", &.{}, &total, &changed);
            }
        }
    }

    if (stat_mode) {
        try ctx.out.print(" {d} file(s) changed, +{d} -{d}\n", .{ changed, total.added, total.removed });
    }
    return if (refused) 1 else 0;
}

/// A symlink apply would remove, shown as its one line `symlink -> <target>`
/// going away.
fn diffLinkRemoval(
    ctx: *app.Ctx,
    sty: style.Style,
    stat_mode: bool,
    live_path: []const u8,
    target: []const u8,
    total: *Stat,
    changed: *usize,
) !void {
    const a_lines = try mox.diff.lines.splitLines(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "symlink -> {s}\n", .{target}));
    const hunks = try mox.diff.lines.diff(ctx.alloc, a_lines, &.{});
    changed.* += 1;
    total.removed += 1;
    if (stat_mode) {
        try ctx.out.print(" {f} | +0 -1\n", .{display.of(live_path, ctx.context.?.paths.home)});
        return;
    }
    try ctx.out.writeAll(try renderFile(ctx.alloc, live_path, a_lines, &.{}, hunks, &.{}, &.{}, sty));
}

/// Diff a symlink apply replaces with the composed file `composed_bytes`.
fn diffLinkReplace(
    ctx: *app.Ctx,
    sty: style.Style,
    stat_mode: bool,
    live_path: []const u8,
    target: []const u8,
    composed_bytes: []const u8,
    prov_segments: []const mox.provenance.map.Segment,
    total: *Stat,
    changed: *usize,
) !void {
    const a_lines = try mox.diff.lines.splitLines(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "symlink -> {s}\n", .{target}));
    const b_lines = try mox.diff.lines.splitLines(ctx.alloc, composed_bytes);
    const hunks = try mox.diff.lines.diff(ctx.alloc, a_lines, b_lines);
    const s = statOf(hunks);
    changed.* += 1;
    total.added += s.added;
    total.removed += s.removed;
    if (stat_mode) {
        try ctx.out.print(" {f} | +{d} -{d}\n", .{ display.of(live_path, ctx.context.?.paths.home), s.added, s.removed });
        return;
    }
    const b_secret = try secretMask(ctx.alloc, b_lines.len, prov_segments);
    try ctx.out.writeAll(try renderFile(ctx.alloc, live_path, a_lines, b_lines, hunks, &.{}, b_secret, sty));
}

/// Diff one composed result against its live file, printing the rendered hunks
/// (or the `--stat` line) and accumulating totals. Shared by an ordinary
/// managed file and by every file a generator produces, so both report the same
/// way. `prov_segments` is the composed side's provenance, used to redact
/// secret-covered lines: a resolved secret is inlined into the composed bytes
/// and must never reach stdout.
fn diffOne(
    ctx: *app.Ctx,
    state_dir: []const u8,
    sty: style.Style,
    stat_mode: bool,
    live_path: []const u8,
    composed_bytes: []const u8,
    prov_segments: []const mox.provenance.map.Segment,
    total: *Stat,
    changed: *usize,
) !void {
    // Kind guard BEFORE the open: a FIFO here would block the read and brick
    // the whole diff.
    if (mox.apply.write.guardLiveRead(ctx.io, live_path) == .special) {
        try ctx.err.print("mox diff: {f}: not a regular file; skipped\n", .{display.of(live_path, ctx.context.?.paths.home)});
        return;
    }
    const live: []const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, live_path, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    if (std.mem.eql(u8, live, composed_bytes)) return;

    const a_lines = try mox.diff.lines.splitLines(ctx.alloc, live);
    const b_lines = try mox.diff.lines.splitLines(ctx.alloc, composed_bytes);
    const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
        error.TooManyLines => {
            try ctx.err.print("mox diff: {f}: too large to diff\n", .{display.of(live_path, ctx.context.?.paths.home)});
            return;
        },
        else => return e,
    };
    if (hunks.len == 0) return;

    changed.* += 1;
    const s = statOf(hunks);
    total.added += s.added;
    total.removed += s.removed;

    if (stat_mode) {
        try ctx.out.print(" {f} | +{d} -{d}\n", .{ display.of(live_path, ctx.context.?.paths.home), s.added, s.removed });
    } else {
        // Composed-side secrets come from this compose's provenance; live-side
        // secrets from the last-applied provenance mox persisted for the path
        // (its resolved values may still sit on disk).
        const b_secret = try secretMask(ctx.alloc, b_lines.len, prov_segments);
        const prior = try mox.provenance.map.read(ctx.alloc, ctx.io, state_dir, live_path);
        const a_secret = if (prior) |m| try secretMask(ctx.alloc, a_lines.len, m.segments) else &.{};
        const rendered = try renderFile(ctx.alloc, live_path, a_lines, b_lines, hunks, a_secret, b_secret, sty);
        try ctx.out.writeAll(rendered);
    }
}

/// Diff one partial file's owned subtree: canonical composed-owned vs
/// canonical live-owned, as text, labeled with the live path. Keys in
/// the secret set -- the record's, plus any path the current compose resolved
/// a secret into -- are masked on BOTH sides before diffing, so a resolved
/// value never reaches stdout. A composed document violating its declaration
/// reports apply's ERROR line on stderr; diff stays read-only and keeps
/// its exit contract.
fn diffPartial(
    ctx: *app.Ctx,
    state_dir: []const u8,
    sty: style.Style,
    stat_mode: bool,
    file: mox.source.tree.ManagedFile,
    composed_bytes: []const u8,
    prov_segments: []const mox.provenance.map.Segment,
    total: *Stat,
    changed: *usize,
) !void {
    const partial_mod = mox.apply.partial;
    const canon_mod = mox.apply.canonical;
    const owned_mod = mox.apply.owned;
    const live_path = file.live_path;
    const own_paths = file.own_paths;
    // The walk only attaches own_paths to structured targets.
    const format = file.format.?;

    const mode: mox.apply.applied.Mode = if (file.ownership == .disown) .disown else .own;
    const owned = partial_mod.OwnedDoc.parse(ctx.alloc, format, composed_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {f} (composed source does not parse as {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), @tagName(format) });
            return;
        },
    };
    switch (mode) {
        .own => if (try partial_mod.undeclaredLeaf(ctx.alloc, &owned, own_paths)) |leaf| {
            try ctx.err.print("  ERROR   {f} (composed leaf {s} is outside the declared own paths)\n", .{ display.of(live_path, ctx.context.?.paths.home), leaf });
            return;
        },
        .disown => if (try partial_mod.populatedDisownPath(ctx.alloc, &owned, own_paths)) |spelled| {
            try ctx.err.print("  ERROR   {f} (composed source defines content under disowned path {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), spelled });
            return;
        },
    }

    // Read through a symlinked live path exactly as apply patches it: via the
    // resolved target. A dangling link is the shape apply refuses.
    const live_target = mox.apply.write.resolvePartialLive(ctx.alloc, ctx.io, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => {
            try ctx.err.print("  ERROR   {f} (live path is a dangling symlink; fix or remove the link)\n", .{display.of(live_path, ctx.context.?.paths.home)});
            return;
        },
    };
    // Kind guard BEFORE the open: a FIFO here would block the read and brick
    // the whole diff.
    if (mox.apply.write.guardLiveRead(ctx.io, live_target) == .special) {
        try ctx.err.print("  ERROR   {f} (not a regular file)\n", .{display.of(live_path, ctx.context.?.paths.home)});
        return;
    }
    const live: []const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, live_target, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const live_doc = partial_mod.OwnedDoc.parse(ctx.alloc, format, live) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            const shown = try std.fmt.allocPrint(ctx.alloc, "{f}", .{display.of(live_path, ctx.context.?.paths.home)});
            try ctx.err.print("  ERROR   {s} ({s}; the live file does not parse)\n", .{ shown, try partial_mod.liveParseError(ctx.alloc, format, live, try std.fmt.allocPrint(ctx.alloc, "live {s}", .{shown})) });
            return;
        },
    };

    var pdiag: partial_mod.Diag = .{};
    const secret_scope: []const mox.source.tree.OwnPath = switch (mode) {
        .own => own_paths,
        .disown => try canon_mod.topLevelPaths(ctx.alloc, &owned),
    };
    const flags = partial_mod.secretPathFlags(ctx.alloc, format, composed_bytes, secret_scope, prov_segments, &pdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {f} (composed source: {s})\n", .{ display.of(live_path, ctx.context.?.paths.home), pdiag.text() });
            return;
        },
    };
    const record = try mox.apply.applied.readOwned(ctx.alloc, ctx.io, state_dir, live_path);
    var secret_paths: std.ArrayList(mox.source.tree.OwnPath) = .empty;
    if (record) |r| try secret_paths.appendSlice(ctx.alloc, try owned_mod.parseRawPaths(ctx.alloc, r.secret_paths));
    for (secret_scope, flags) |p, flagged| {
        if (flagged and !owned_mod.pathInList(p.segments, secret_paths.items)) {
            try secret_paths.append(ctx.alloc, p);
        }
    }
    const spelled = try ctx.alloc.alloc([]const u8, secret_paths.items.len);
    for (secret_paths.items, spelled) |p, *s| s.* = try canon_mod.pathSpell(ctx.alloc, p.segments);

    const composed_x = switch (mode) {
        .own => try canon_mod.canonicalOwned(ctx.alloc, &owned, own_paths),
        .disown => try canon_mod.canonicalComplement(ctx.alloc, &owned, own_paths),
    };
    const live_x = switch (mode) {
        .own => try canon_mod.canonicalOwned(ctx.alloc, &live_doc, own_paths),
        .disown => try canon_mod.canonicalComplement(ctx.alloc, &live_doc, own_paths),
    };
    const b_text = try maskOwnedSections(ctx.alloc, composed_x, spelled);
    const a_text = try maskOwnedSections(ctx.alloc, live_x, spelled);
    if (std.mem.eql(u8, a_text, b_text)) {
        // Drift confined to secret paths: both sides mask to the same bytes,
        // and silence here would read as "no drift".
        if (!std.mem.eql(u8, live_x, composed_x)) {
            try ctx.out.print("{f}: (no visible difference; the owned changes are under secret paths)\n", .{display.of(live_path, ctx.context.?.paths.home)});
        }
        return;
    }

    const a_lines = try mox.diff.lines.splitLines(ctx.alloc, a_text);
    const b_lines = try mox.diff.lines.splitLines(ctx.alloc, b_text);
    const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
        error.TooManyLines => {
            try ctx.err.print("mox diff: {f}: too large to diff\n", .{display.of(live_path, ctx.context.?.paths.home)});
            return;
        },
        else => return e,
    };
    if (hunks.len == 0) return;

    changed.* += 1;
    const s = statOf(hunks);
    total.added += s.added;
    total.removed += s.removed;
    if (stat_mode) {
        try ctx.out.print(" {f} | +{d} -{d}\n", .{ display.of(live_path, ctx.context.?.paths.home), s.added, s.removed });
    } else {
        const rendered = try renderOwnedFile(ctx.alloc, live_path, a_lines, b_lines, hunks, sty);
        try ctx.out.writeAll(rendered);
    }
}

/// A canonical blob with each named section's body replaced by the secret
/// mask. The header line stays, so a section appearing or disappearing still
/// shows; every key and value under it is hidden. Sections absent from the
/// blob are left alone.
pub fn maskOwnedSections(arena: std.mem.Allocator, blob: []const u8, spelled_paths: []const []const u8) ![]const u8 {
    var text: []const u8 = blob;
    for (spelled_paths) |sp| {
        const sec = mox.apply.canonical.sectionOf(text, sp) orelse continue;
        const start = @intFromPtr(sec.ptr) - @intFromPtr(text.ptr);
        const header_len = (std.mem.indexOfScalar(u8, sec, '\n') orelse (sec.len - 1)) + 1;
        text = try std.mem.concat(arena, u8, &.{
            text[0 .. start + header_len],
            "  " ++ mox.apply.partial.secret_mask ++ "\n",
            text[start + sec.len ..],
        });
    }
    return text;
}

pub const command = app.command(Spec, .{
    .name = "diff",
    .usage = "mox diff [--flags] [<paths...>]",
    .summary = "Show a unified diff of composed output vs each live file",
    .details = "Read-only and takes no lock. A difference is not an error: exit 0 whether or not anything differs. Exit 2 when an attributes.toml, the repo's or the private layer's, is not valid TOML or cannot be read. Exit 1 on a refusal: a path that is not managed, a head ownership declaration that does not parse, or an attributes entry that breaks the schema. A file's own ERROR -- a head directive on an unstructured target or spelled with another file's comment marker, a mox directive in strict JSON, a layer or output that does not parse -- is reported and exits 0.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "statOf: sums added and removed across hunks" {
    const hunks = [_]Hunk{
        .{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 2 },
        .{ .a_start = 5, .a_len = 3, .b_start = 6, .b_len = 0 },
    };
    const s = statOf(&hunks);
    try testing.expectEqual(@as(usize, 2), s.added);
    try testing.expectEqual(@as(usize, 4), s.removed);
}

test "renderFile: a changed line renders both sides under a hunk header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "two", "three" };
    const b = [_][]const u8{ "one", "TWO", "three" };
    const hunks = [_]Hunk{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }};
    const no_secret: []const bool = &.{};
    const off = style.Style{ .on = false };
    const out = try renderFile(arena.allocator(), "/home/me/.zshrc", &a, &b, &hunks, no_secret, no_secret, off);
    const expected =
        "--- /home/me/.zshrc (live)\n" ++
        "+++ /home/me/.zshrc (composed)\n" ++
        "@@ -2,1 +2,1 @@\n" ++
        "-two\n" ++
        "+TWO\n";
    try testing.expectEqualStrings(expected, out);
}

test "renderFile: no hunks renders empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty: []const []const u8 = &.{};
    const no_secret: []const bool = &.{};
    const off = style.Style{ .on = false };
    const out = try renderFile(arena.allocator(), "x", empty, empty, &.{}, no_secret, no_secret, off);
    try testing.expectEqualStrings("", out);
}

test "renderFile: a hunk secret on both masks redacts its removed and added lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "user = me", "token = old-s3cr3t" };
    const b = [_][]const u8{ "user = me", "token = new-s3cr3t" };
    const hunks = [_]Hunk{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }};
    // Line 1 is a resolved secret on both sides.
    const a_secret = [_]bool{ false, true };
    const b_secret = [_]bool{ false, true };
    const off = style.Style{ .on = false };
    const out = try renderFile(arena.allocator(), "/home/me/.netrc", &a, &b, &hunks, &a_secret, &b_secret, off);
    const red = mox.provenance.map.secret_redaction;
    const expected =
        "--- /home/me/.netrc (live)\n" ++
        "+++ /home/me/.netrc (composed)\n" ++
        "@@ -2,1 +2,1 @@\n" ++
        "-" ++ red ++ "\n" ++
        "+" ++ red ++ "\n";
    try testing.expectEqualStrings(expected, out);
    try testing.expect(std.mem.indexOf(u8, out, "s3cr3t") == null);
}

test "maskOwnedSections: named section bodies are masked, others left verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blob = "= api\n  token = \"s3cr3t\"\n  user = \"me\"\n= ui\n  color = \"red\"\n";
    const got = try maskOwnedSections(arena.allocator(), blob, &.{ "api", "absent" });
    const want = "= api\n  " ++ mox.apply.partial.secret_mask ++ "\n= ui\n  color = \"red\"\n";
    try testing.expectEqualStrings(want, got);
    try testing.expect(std.mem.indexOf(u8, got, "s3cr3t") == null);
}

test "renderFile: colored output wraps removed lines red, added lines green, headers dim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{"two"};
    const b = [_][]const u8{"TWO"};
    const hunks = [_]Hunk{.{ .a_start = 0, .a_len = 1, .b_start = 0, .b_len = 1 }};
    const no_secret: []const bool = &.{};
    const on = style.Style{ .on = true };
    const out = try renderFile(arena.allocator(), "x", &a, &b, &hunks, no_secret, no_secret, on);
    const expected =
        "\x1b[2m--- x (live)\n" ++
        "+++ x (composed)\n\x1b[0m" ++
        "\x1b[2m@@ -1,1 +1,1 @@\n\x1b[0m" ++
        "\x1b[31m-two\n\x1b[0m" ++
        "\x1b[32m+TWO\n\x1b[0m";
    try testing.expectEqualStrings(expected, out);
}
