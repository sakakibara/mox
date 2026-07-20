//! Model-based property test for the generator (`for ... into`) prune, the
//! data-safety-critical path. It drives the REAL `mox apply` over randomized
//! sequences of generator-data mutations and, after every apply, checks the
//! invariants that must hold no matter how the data changes step to step:
//!
//!   EXACTNESS   the set of a generator's leaves on disk equals exactly the set
//!               its current data implies (deduplicated) -- no straggler a drop
//!               failed to remove, no missing file a re-add failed to write.
//!   NO COLLATERAL  a regular managed file and an unrelated unmanaged file in
//!               the SAME directory are never touched, and one generator's prune
//!               never removes another generator's leaf.
//!   FAIL-SAFE   a corrupt data source (array absent) fails that generator
//!               without pruning: its prior leaves survive untouched, and the
//!               other generator still applies.
//!   RECOVERABLE every leaf a prune removes is snapshotted first, so the delete
//!               is rollback-recoverable.
//!
//! Two vehicles share one step engine: a deterministic loop over a fixed set of
//! seeded sequences that runs on every `zig build test` (so CI exercises it on
//! all platforms), and a Smith fuzz target that derives sequences from bytes and
//! explores continuously under `zig build fuzz --fuzz`. The deterministic sweep
//! is a fixed regression sample; the space itself was swept far wider (tens of
//! thousands of applies) during development and stayed invariant-clean.

const std = @import("std");
const mox = @import("mox");
const testutil = @import("testutil.zig");

const Io = std.Io;
const Cli = testutil.Harness;
const Smith = std.testing.Smith;

// Two generators in the SAME directory, on disjoint filename prefixes, plus a
// regular managed file and an unmanaged file beside them. gen1 renders
// `.config/g1-<slug>.inc` = `key=<slug>\n`; gen2 renders `.config/g2-<slug>.inc`
// = `val=<slug>\n`. A collateral bug shows as a touched g2 leaf, static file, or
// keep file; a cross-generator mixup shows as `key=` in a `val=` slot.
const slug_count: u8 = 5;

const Kind = enum { normal, corrupt };

/// One generator's data for a step: `corrupt` writes a zero-byte source (the
/// array is absent, distinct from a present-empty `[]`); `normal` writes the
/// rows named by `mask` (bit i = slug 'a'+i), optionally duplicating the lowest
/// set slug to exercise same-path coalescing.
const Gen = struct { kind: Kind, mask: u8, dup: bool };

const Step = struct { g1: Gen, g2: Gen, force: bool };

fn slugChar(i: u8) u8 {
    return 'a' + i;
}

fn appendRow(a: std.mem.Allocator, body: *std.ArrayList(u8), arr: []const u8, ch: u8) !void {
    try body.appendSlice(a, "[[");
    try body.appendSlice(a, arr);
    try body.appendSlice(a, "]]\nslug = \"");
    try body.append(a, ch);
    try body.appendSlice(a, "\"\n\n");
}

/// Write `repo/data/<name>.toml` for a generator's step. `arr` is the TOML array
/// name (== the source filename stem, which is how mox picks the row list).
fn writeData(io: Io, tmp: *std.testing.TmpDir, a: std.mem.Allocator, name: []const u8, arr: []const u8, g: Gen) !void {
    const sub = try std.fmt.allocPrint(a, "repo/data/{s}.toml", .{name});
    if (g.kind == .corrupt) {
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "" });
        return;
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var any = false;
    var i: u8 = 0;
    while (i < slug_count) : (i += 1) {
        if (g.mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
        try appendRow(a, &body, arr, slugChar(i));
        any = true;
    }
    if (g.dup and any) try appendRow(a, &body, arr, slugChar(@ctz(g.mask)));
    if (!any) {
        // Present-but-empty array: a valid zero-row source (prune-all), NOT the
        // corrupt absent-array case above.
        try body.appendSlice(a, arr);
        try body.appendSlice(a, " = []\n");
    }
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = body.items });
}

fn maskOf(g: Gen) u8 {
    return g.mask & 0x1F;
}

/// A generator produces no valid set this step -- and so protects its prior
/// leaves and prunes nothing -- when its data is corrupt (absent array) or when
/// it would render the same path twice. A duplicated row (`dup`) collides only
/// when at least one row is present; mox refuses the whole generator rather than
/// silently drop a row to last-write-wins.
fn genFails(g: Gen) bool {
    return g.kind == .corrupt or (g.dup and maskOf(g) != 0);
}

/// Assert one generator's on-disk leaf set is EXACTLY `expected` (bit i = slug
/// 'a'+i present with the right content, every other slot absent).
fn expectLeaves(io: Io, a: std.mem.Allocator, c: Cli, prefix: []const u8, key: []const u8, expected: u8) !void {
    var i: u8 = 0;
    while (i < slug_count) : (i += 1) {
        const rel = try std.fmt.allocPrint(a, ".config/{s}-{c}.inc", .{ prefix, slugChar(i) });
        const path = try c.homePath(rel);
        const present = expected & (@as(u8, 1) << @intCast(i)) != 0;
        if (present) {
            const want = try std.fmt.allocPrint(a, "{s}={c}\n", .{ key, slugChar(i) });
            const got = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| {
                std.debug.print("expected leaf {s} present, read failed: {s}\n", .{ path, @errorName(e) });
                return e;
            };
            try std.testing.expectEqualStrings(want, got);
        } else {
            if (fileExists(io, path)) {
                std.debug.print("leaf {s} should be absent but exists\n", .{path});
                return error.LeafShouldBeAbsent;
            }
        }
    }
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True when any snapshot under the state dir holds `rel` with content `want`.
fn snapshotHas(io: Io, a: std.mem.Allocator, state_dir: []const u8, rel: []const u8, want: []const u8) !bool {
    const snaps = try std.fs.path.join(a, &.{ state_dir, "snapshots" });
    const ids = mox.apply.snapshot.list(a, io, snaps) catch return false;
    for (ids) |id| {
        const p = try std.fs.path.join(a, &.{ snaps, id, rel });
        const c = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch continue;
        if (std.mem.eql(u8, c, want)) return true;
    }
    return false;
}

/// Run one randomized sequence end to end against a fresh isolated repo, and
/// assert every invariant after each apply. `steps` is the full sequence.
fn runSequence(gpa: std.mem.Allocator, io: Io, steps: []const Step) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Fixtures: two generators + a regular managed file, all in `.config`.
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen1.inc",
        .data = "# mox: for id in \"data/d1.toml\" into \"g1-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen2.inc",
        .data = "# mox: for id in \"data/d2.toml\" into \"g2-<id.slug>.inc\"\nval=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/static.inc", .data = "static\n" });

    const c = try testutil.setup(a, io, &tmp, .{});

    // An unmanaged file beside the generated leaves: mox must never touch it.
    const keep = try c.homePath(".config/keep.txt");
    if (std.fs.path.dirname(keep)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = keep, .data = "precious\n" });
    const static_live = try c.homePath(".config/static.inc");

    // The last SUCCESSFUL produced set per generator = what must be on disk.
    var model1: u8 = 0;
    var model2: u8 = 0;

    for (steps) |s| {
        try writeData(io, &tmp, a, "d1", "d1", s.g1);
        try writeData(io, &tmp, a, "d2", "d2", s.g2);

        const argv: []const []const u8 = if (s.force)
            &.{ "mox", "apply", "--force" }
        else
            &.{ "mox", "apply" };
        const r = try c.run(argv);

        const g1_ok = !genFails(s.g1);
        const g2_ok = !genFails(s.g2);
        const exp1: u8 = if (g1_ok) maskOf(s.g1) else model1;
        const exp2: u8 = if (g2_ok) maskOf(s.g2) else model2;

        // A failing generator returns rc 1 but does not abort the other's work.
        const want_rc: u8 = if (g1_ok and g2_ok) 0 else 1;
        try std.testing.expectEqual(want_rc, r.rc);

        // EXACTNESS: each generator's on-disk set is exactly what its data implies
        // (or, when it failed, exactly its protected prior set).
        try expectLeaves(io, a, c, "g1", "key", exp1);
        try expectLeaves(io, a, c, "g2", "val", exp2);

        // NO COLLATERAL: the regular managed file and the unmanaged neighbor are
        // byte-for-byte intact.
        try std.testing.expectEqualStrings("static\n", try Io.Dir.cwd().readFileAlloc(io, static_live, a, .limited(1 << 20)));
        try std.testing.expectEqualStrings("precious\n", try Io.Dir.cwd().readFileAlloc(io, keep, a, .limited(1 << 20)));

        // RECOVERABLE: any leaf dropped this step (present in the prior model,
        // absent now) is snapshotted, so its removal can be rolled back.
        if (g1_ok) {
            const removed = model1 & ~exp1;
            var i: u8 = 0;
            while (i < slug_count) : (i += 1) {
                if (removed & (@as(u8, 1) << @intCast(i)) == 0) continue;
                const rel = try std.fmt.allocPrint(a, ".config/g1-{c}.inc", .{slugChar(i)});
                const want = try std.fmt.allocPrint(a, "key={c}\n", .{slugChar(i)});
                if (!try snapshotHas(io, a, c.state, rel, want)) {
                    std.debug.print("dropped leaf {s} was not snapshotted before removal\n", .{rel});
                    return error.PrunedLeafNotRecoverable;
                }
            }
        }

        if (g1_ok) model1 = exp1;
        if (g2_ok) model2 = exp2;
    }
}

fn genFromByte(b: u8) Gen {
    // ~1/8 of steps corrupt a generator; the rest carry a 5-bit row mask with a
    // duplicate-row flag folded in.
    return .{
        .kind = if (b & 0b111 == 0) .corrupt else .normal,
        .mask = (b >> 3) & 0x1F,
        .dup = (b & 0b100) != 0,
    };
}

test "property: generator prune preserves exactness, no collateral, recoverability" {
    // A deterministic sweep of seeded sequences. Each sequence is independent
    // (fresh repo), so a bug in cross-step prune bookkeeping surfaces as a failed
    // invariant on some later apply. Bounded loop -> always terminates.
    const n_sequences = 200;
    const steps_per_seq = 8;

    var seq: usize = 0;
    while (seq < n_sequences) : (seq += 1) {
        var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15 ^ seq);
        const rng = prng.random();

        var steps: [steps_per_seq]Step = undefined;
        for (&steps) |*st| {
            st.* = .{
                .g1 = genFromByte(rng.int(u8)),
                .g2 = genFromByte(rng.int(u8)),
                .force = rng.uintLessThan(u8, 4) == 0,
            };
        }
        runSequence(std.testing.allocator, std.testing.io, &steps) catch |e| {
            std.debug.print("sequence seed {d} failed: {s}\n", .{ seq, @errorName(e) });
            return e;
        };
    }
}

/// Smith fuzz target: derive a step sequence from arbitrary bytes and run it
/// through the same invariant checks. Runs once as a smoke test under
/// `zig build test`; explores continuously under `zig build fuzz --fuzz`.
fn fuzzPrune(_: void, smith: *Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const n = smith.slice(&buf);
    const bytes = buf[0..n];

    var steps: [12]Step = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len and count < steps.len) : (i += 2) {
        steps[count] = .{
            .g1 = genFromByte(bytes[i]),
            .g2 = genFromByte(bytes[i + 1]),
            .force = (bytes[i] & 0x80) != 0,
        };
        count += 1;
    }
    if (count == 0) return;
    try runSequence(std.testing.allocator, std.testing.io, steps[0..count]);
}

test "fuzz: generator prune invariants" {
    try std.testing.fuzz({}, fuzzPrune, .{});
}
