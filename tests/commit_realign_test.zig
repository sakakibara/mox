//! Bounded exhaustive check of how `mox commit` realigns a file with a loop
//! or with lines from more than one source. Small layouts of base lines, an
//! included repo fragment, a private-layer region and loops are applied;
//! every edit of up to K user operations is written over the live file, and
//! the real `mox commit` runs over it. What it leaves in the sources is
//! compared with a minimum-operation oracle: the edit's interpretations with
//! the fewest operations, a line insertion, deletion or replacement one
//! operation and a whole-row insertion or deletion one.
//!
//! `zig build test` runs a sample; `zig build test-realign` runs every edit
//! of the full sweep, best with `-Doptimize=ReleaseFast` and split across
//! processes with `MOX_REALIGN_SHARD=<i>/<n>`. A run is bounded in commit
//! runs and in wall-clock time, a watchdog ending it inside a commit that
//! never returns, so a regression fails rather than hangs.

const std = @import("std");
const mox = @import("mox");
const testutil = @import("testutil.zig");
const realign_options = @import("realign_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Part = union(enum) { capture, constant: []const u8 };

const Loop = struct {
    parts: []const Part,
    /// The capture line renders as `pre` followed by the row's value.
    pre: []const u8,
    ds: u8,
    /// The values a row must hold to render; null renders every row.
    where: ?[]const []const u8 = null,
    /// The body is wrapped in a gate, so its rows carry no row provenance.
    nested: bool = false,
};

const Cfg = struct {
    name: []const u8,
    loops: []const Loop,
    /// Each data source's row values, sorted.
    doms: []const []const []const u8,
    /// Every text a literal holds or an edit writes.
    texts: []const []const u8,

    fn passes(c: Cfg, lp: usize, v: []const u8) bool {
        const w = c.loops[lp].where orelse return true;
        return contains(w, v);
    }

    fn shared(c: Cfg, lp: usize) bool {
        var n: usize = 0;
        for (c.loops) |l| {
            if (l.ds == c.loops[lp].ds) n += 1;
        }
        return n > 1;
    }

    /// Whether `t` is the capture line of some value of the loop's source.
    fn fitv(c: Cfg, lp: usize, t: []const u8) bool {
        const l = c.loops[lp];
        if (!std.mem.startsWith(u8, t, l.pre)) return false;
        return contains(c.doms[l.ds], t[l.pre.len..]);
    }

    fn captureIndex(c: Cfg, lp: usize) u8 {
        for (c.loops[lp].parts, 0..) |p, i| {
            if (p == .capture) return @intCast(i);
        }
        unreachable;
    }
};

fn contains(set: []const []const u8, v: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

const Cont = enum(u8) { b, F, P };

const Lit = struct { id: u32, text: []const u8 };
const Item = union(enum) { lit: Lit, inc: Cont, loop: u8 };
const Row = struct { rid: u32, v: []const u8 };

const State = struct {
    base: []const Item,
    f: []const Lit,
    p: []const Lit,
    data: []const []const Row,

    fn cont(s: State, c: Cont) []const Lit {
        return switch (c) {
            .F => s.f,
            .P => s.p,
            .b => unreachable,
        };
    }
};

const Tag = union(enum) {
    lit: struct { cont: Cont, id: u32 },
    /// `pi` counts the row's output lines, a value's own lines included.
    row: struct { lp: u8, rid: u32, pi: u8 },
};

const Line = struct { text: []const u8, tag: Tag };

fn render(a: Allocator, cfg: Cfg, st: State) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    for (st.base) |it| switch (it) {
        .lit => |l| try out.append(a, .{ .text = l.text, .tag = .{ .lit = .{ .cont = .b, .id = l.id } } }),
        .inc => |c| for (st.cont(c)) |l| try out.append(a, .{ .text = l.text, .tag = .{ .lit = .{ .cont = c, .id = l.id } } }),
        .loop => |lp| {
            const loop = cfg.loops[lp];
            for (st.data[loop.ds]) |r| {
                if (!cfg.passes(lp, r.v)) continue;
                var li: u8 = 0;
                for (loop.parts) |p| {
                    const text = switch (p) {
                        .capture => try std.mem.concat(a, u8, &.{ loop.pre, r.v }),
                        .constant => |k| k,
                    };
                    var parts = std.mem.splitScalar(u8, text, '\n');
                    while (parts.next()) |line| {
                        try out.append(a, .{ .text = line, .tag = .{ .row = .{ .lp = lp, .rid = r.rid, .pi = li } } });
                        li += 1;
                    }
                }
            }
        },
    };
    return out.toOwnedSlice(a);
}

const Elem = union(enum) {
    lit: struct { cont: Cont, id: u32 },
    row: struct { lp: u8, rid: u32 },
};

const Gap = struct { g: u32, k: u32 };

const Lay = struct {
    cfg: Cfg,
    st: State,
    a: []const []const u8,
    tags: []const Tag,
    elems: []const Elem,
    line_el: []const u32,
    /// Per loop, the gap and position among the gap's empty loops, for a
    /// loop that renders nothing.
    empty_gap: []const ?Gap,
    /// Per gap, how many empty loops sit there.
    empty_at: []const u32,

    fn init(a: Allocator, cfg: Cfg, st: State) !Lay {
        const lines = try render(a, cfg, st);
        const texts = try a.alloc([]const u8, lines.len);
        const tags = try a.alloc(Tag, lines.len);
        var elems: std.ArrayList(Elem) = .empty;
        const line_el = try a.alloc(u32, lines.len);
        for (lines, 0..) |l, i| {
            texts[i] = l.text;
            tags[i] = l.tag;
            switch (l.tag) {
                .lit => |t| try elems.append(a, .{ .lit = .{ .cont = t.cont, .id = t.id } }),
                .row => |t| if (t.pi == 0) try elems.append(a, .{ .row = .{ .lp = t.lp, .rid = t.rid } }),
            }
            line_el[i] = @intCast(elems.items.len - 1);
        }
        const empty_gap = try a.alloc(?Gap, cfg.loops.len);
        @memset(empty_gap, null);
        const empty_at = try a.alloc(u32, elems.items.len + 1);
        @memset(empty_at, 0);
        // Each loop's output position, walking the base in order.
        var pos: usize = 0;
        for (st.base) |it| switch (it) {
            .lit => pos += 1,
            .inc => |c| pos += st.cont(c).len,
            .loop => |lp| {
                var n: usize = 0;
                for (st.data[cfg.loops[lp].ds]) |r| {
                    if (cfg.passes(lp, r.v)) n += cfg.loops[lp].parts.len + std.mem.count(u8, r.v, "\n");
                }
                if (n == 0) {
                    const g: u32 = if (pos > 0) line_el[pos - 1] + 1 else 0;
                    empty_gap[lp] = .{ .g = g, .k = empty_at[g] };
                    empty_at[g] += 1;
                }
                pos += n;
            },
        };
        return .{ .cfg = cfg, .st = st, .a = texts, .tags = tags, .elems = try elems.toOwnedSlice(a), .line_el = line_el, .empty_gap = empty_gap, .empty_at = empty_at };
    }

    fn rowValue(l: Lay, d: u8, rid: u32) []const u8 {
        for (l.st.data[d]) |r| {
            if (r.rid == rid) return r.v;
        }
        unreachable;
    }

    /// How many output lines row element `e` renders.
    fn rowLines(l: Lay, e: u32) u8 {
        var n: u8 = 0;
        for (l.line_el) |x| {
            if (x == e) n += 1;
        }
        return n;
    }

    fn firstLineOf(l: Lay, e: u32) usize {
        for (l.line_el, 0..) |x, i| {
            if (x == e) return i;
        }
        unreachable;
    }
};

/// Where an insertion goes: inside a loop's rows (not representable), the
/// base (`sub` counts the empty loops at the gap it follows), or a fragment.
const Slot = struct { cont: enum(u8) { in, b, F, P }, sub: u8 = 0 };

const Op = struct {
    kind: Kind,
    e: u32 = 0,
    pi: u8 = 0,
    t: []const u8 = "",
    d: u8 = 0,
    rid: u32 = 0,
    pos: u32 = 0,
    slot: Slot = .{ .cont = .in },

    const Kind = enum { brep, bdel, rowbad, crep, cdel, xdel, pins, rowset, rowdel, rowins, bins, bput };

    fn eql(x: Op, y: Op) bool {
        return x.kind == y.kind and x.e == y.e and x.pi == y.pi and std.mem.eql(u8, x.t, y.t) and x.d == y.d and
            x.rid == y.rid and x.pos == y.pos and x.slot.cont == y.slot.cont and x.slot.sub == y.slot.sub;
    }

    fn isIns(o: Op) bool {
        return o.kind == .bins or o.kind == .rowins or o.kind == .pins;
    }

    fn isUnrep(o: Op) bool {
        return switch (o.kind) {
            .rowbad, .crep, .cdel, .xdel, .pins => true,
            else => false,
        };
    }

    fn isRow(o: Op) bool {
        return o.kind == .rowset or o.kind == .rowdel or o.kind == .rowins;
    }

    /// Two operations on one element, one constant line or one data row
    /// cannot be combined.
    fn key(o: Op) ?[3]u32 {
        return switch (o.kind) {
            .brep, .bdel, .rowbad, .xdel => .{ 0, o.e, 0 },
            .crep, .cdel => .{ 1, o.e, o.pi },
            .rowset, .rowdel => .{ 2, o.d, o.rid },
            else => null,
        };
    }

    /// Insertions at one place, whose order matters.
    fn gkey(o: Op) [4]u32 {
        return switch (o.kind) {
            .bins => .{ 0, o.pos, @intFromEnum(o.slot.cont), o.slot.sub },
            .rowins => .{ 1, o.d, o.pos, 0 },
            else => .{ 2, o.e, o.pi, 0 },
        };
    }
};

fn gapSlots(a: Allocator, lay: Lay, g: u32) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    const n = lay.elems.len;
    const prv: ?Elem = if (g > 0) lay.elems[g - 1] else null;
    const nxt: ?Elem = if (g < n) lay.elems[g] else null;
    if (prv != null and nxt != null and prv.? == .row and nxt.? == .row and prv.?.row.lp == nxt.?.row.lp) {
        try out.append(a, .{ .cont = .in });
        return out.toOwnedSlice(a);
    }
    const kp: ?Cont = if (prv) |p| (if (p == .lit) p.lit.cont else null) else null;
    const kn: ?Cont = if (nxt) |p| (if (p == .lit) p.lit.cont else null) else null;
    if (kp == .F or kn == .F) try out.append(a, .{ .cont = .F });
    if (kp == .P or kn == .P) try out.append(a, .{ .cont = .P });
    if (!(kp != null and kp == kn and kp.? != .b)) {
        var k: u32 = 0;
        while (k <= lay.empty_at[g]) : (k += 1) try out.append(a, .{ .cont = .b, .sub = @intCast(k) });
    }
    return out.toOwnedSlice(a);
}

fn opsFor(a: Allocator, lay: Lay) ![]Op {
    const cfg = lay.cfg;
    var ops: std.ArrayList(Op) = .empty;
    for (lay.elems, 0..) |el, ei_| {
        const ei: u32 = @intCast(ei_);
        switch (el) {
            .lit => {
                const cur = lay.a[lay.firstLineOf(ei)];
                for (cfg.texts) |t| {
                    if (!std.mem.eql(u8, t, cur)) try ops.append(a, .{ .kind = .brep, .e = ei, .t = t });
                }
                try ops.append(a, .{ .kind = .bdel, .e = ei });
            },
            .row => |r| {
                const loop = cfg.loops[r.lp];
                const cur = lay.rowValue(loop.ds, r.rid);
                const cur_line = try std.mem.concat(a, u8, &.{ loop.pre, cur });
                for (cfg.texts) |t| {
                    if (!std.mem.eql(u8, cur_line, t) and (!cfg.fitv(r.lp, t) or cfg.shared(r.lp))) try ops.append(a, .{ .kind = .rowbad, .e = ei, .t = t });
                }
                // Every line but the capture's first: a constant line or a
                // value's further line, neither representable when edited.
                const first = lay.firstLineOf(ei);
                const n = lay.rowLines(ei);
                const cap_line = cfg.captureIndex(r.lp);
                for (0..n) |li| {
                    if (li == cap_line) continue;
                    const k = lay.a[first + li];
                    for (cfg.texts) |t| {
                        if (!std.mem.eql(u8, t, k)) try ops.append(a, .{ .kind = .crep, .e = ei, .pi = @intCast(li), .t = t });
                    }
                    try ops.append(a, .{ .kind = .cdel, .e = ei, .pi = @intCast(li) });
                }
                if (n > 1 or cfg.shared(r.lp)) {
                    try ops.append(a, .{ .kind = .xdel, .e = ei });
                    for (0..n - 1) |li| {
                        for (cfg.texts) |t| try ops.append(a, .{ .kind = .pins, .e = ei, .pi = @intCast(li), .t = t });
                    }
                }
            },
        }
    }
    for (lay.st.data, 0..) |rows, d_| {
        const d: u8 = @intCast(d_);
        for (rows) |r| {
            for (cfg.doms[d]) |w| {
                if (!std.mem.eql(u8, w, r.v)) try ops.append(a, .{ .kind = .rowset, .d = d, .rid = r.rid, .t = w });
            }
            try ops.append(a, .{ .kind = .rowdel, .d = d, .rid = r.rid });
        }
        for (0..rows.len + 1) |pos| {
            for (cfg.doms[d]) |w| try ops.append(a, .{ .kind = .rowins, .d = d, .pos = @intCast(pos), .t = w });
        }
    }
    var g: u32 = 0;
    while (g <= lay.elems.len) : (g += 1) {
        for (try gapSlots(a, lay, g)) |slot| {
            for (cfg.texts) |t| try ops.append(a, .{ .kind = .bins, .pos = g, .t = t, .slot = slot });
        }
    }
    return ops.toOwnedSlice(a);
}

/// Every combination of up to `k` operations, each insertion group in every
/// order, calling `emit` with each. `scratch` is reset for each combination.
fn genCombos(scratch: *std.heap.ArenaAllocator, lay: Lay, ops: []const Op, k: usize, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const Op) anyerror!void) !void {
    var idx: [3]usize = undefined;
    var kk: usize = 1;
    while (kk <= k) : (kk += 1) {
        try genFrom(scratch, lay, ops, idx[0..kk], 0, 0, ctx, emit);
    }
}

fn genFrom(scratch: *std.heap.ArenaAllocator, lay: Lay, ops: []const Op, idx: []usize, depth: usize, from: usize, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const Op) anyerror!void) !void {
    if (depth == idx.len) {
        var combo: [3]Op = undefined;
        for (idx, 0..) |i, j| combo[j] = ops[i];
        _ = scratch.reset(.retain_capacity);
        return emitOrders(scratch.allocator(), lay, combo[0..idx.len], ctx, emit);
    }
    var i = from;
    while (i < ops.len) : (i += 1) {
        idx[depth] = i;
        try genFrom(scratch, lay, ops, idx, depth + 1, i, ctx, emit);
    }
}

fn emitOrders(a: Allocator, lay: Lay, combo: []const Op, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const Op) anyerror!void) !void {
    // One operation per element, constant line or row.
    for (combo, 0..) |x, i| {
        const kx = x.key() orelse continue;
        for (combo[i + 1 ..]) |y| {
            const ky = y.key() orelse continue;
            if (std.mem.eql(u32, &kx, &ky)) return;
        }
    }
    // Only insertions repeat.
    for (combo, 0..) |x, i| {
        if (x.isIns()) continue;
        for (combo[i + 1 ..]) |y| {
            if (!y.isIns() and x.eql(y)) return;
        }
    }
    // No unrepresentable edit of a row the combination deletes, nor of one
    // whose lines a new value holding a newline renumbers.
    for (combo) |x| {
        if (x.kind != .rowdel and x.kind != .rowset) continue;
        if (x.kind == .rowset and std.mem.indexOfScalar(u8, x.t, '\n') == null and
            std.mem.indexOfScalar(u8, lay.rowValue(x.d, x.rid), '\n') == null) continue;
        for (combo) |y| {
            if (!y.isUnrep()) continue;
            const el = lay.elems[y.e].row;
            if (lay.cfg.loops[el.lp].ds == x.d and el.rid == x.rid) return;
        }
    }
    var nonins: [3]Op = undefined;
    var nn: usize = 0;
    var ins: [3]Op = undefined;
    var ni: usize = 0;
    for (combo) |x| {
        if (x.isIns()) {
            ins[ni] = x;
            ni += 1;
        } else {
            nonins[nn] = x;
            nn += 1;
        }
    }
    // Insertions sorted by place, each place's group in every distinct order.
    std.mem.sort(Op, ins[0..ni], {}, struct {
        fn lt(_: void, x: Op, y: Op) bool {
            return std.mem.order(u32, &x.gkey(), &y.gkey()) == .lt;
        }
    }.lt);
    var seen: std.ArrayList([3]Op) = .empty;
    var perm: [3]usize = .{ 0, 1, 2 };
    try permute(a, ins[0..ni], perm[0..ni], 0, nonins[0..nn], &seen, ctx, emit);
}

fn permute(a: Allocator, ins: []const Op, perm: []usize, i: usize, nonins: []const Op, seen: *std.ArrayList([3]Op), ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const Op) anyerror!void) !void {
    if (i == perm.len) {
        // Insertions stay grouped by place; only orders within a place vary.
        for (perm[0..perm.len -| 1], 1..) |p, j| {
            if (std.mem.order(u32, &ins[p].gkey(), &ins[perm[j]].gkey()) == .gt) return;
        }
        var ordered: [3]Op = undefined;
        for (perm, 0..) |p, j| ordered[j] = ins[p];
        for (seen.items) |s| {
            var same = true;
            for (0..perm.len) |j| {
                if (!s[j].eql(ordered[j])) same = false;
            }
            if (same) return;
        }
        try seen.append(a, ordered);
        var full: [3]Op = undefined;
        for (nonins, 0..) |x, j| full[j] = x;
        for (0..perm.len) |j| full[nonins.len + j] = ordered[j];
        return emit(ctx, full[0 .. nonins.len + perm.len]);
    }
    var j = i;
    while (j < perm.len) : (j += 1) {
        std.mem.swap(usize, &perm[i], &perm[j]);
        try permute(a, ins, perm, i + 1, nonins, seen, ctx, emit);
        std.mem.swap(usize, &perm[i], &perm[j]);
    }
}

/// The representable part of a combination: a replacement is its deletion
/// plus its insertion, placed after every other insertion at that position.
fn atoms(a: Allocator, combo: []const Op) ![]Op {
    var out: std.ArrayList(Op) = .empty;
    var late: std.ArrayList(Op) = .empty;
    for (combo) |o| {
        if (o.kind == .brep) {
            try out.append(a, .{ .kind = .bdel, .e = o.e });
            try late.append(a, .{ .kind = .bput, .e = o.e, .t = o.t });
        } else if (o.isUnrep() or (o.kind == .bins and o.slot.cont == .in)) {
            continue;
        } else try out.append(a, o);
    }
    try out.appendSlice(a, late.items);
    return out.toOwnedSlice(a);
}

var next_id: u32 = 1_000_000;

fn newId() u32 {
    next_id += 1;
    return next_id;
}

/// The source state `atoms` leave.
fn applySrc(a: Allocator, lay: Lay, ops: []const Op) !State {
    const E = lay.elems;
    const Key = struct { g: u32, c: u8, sub: u8 };
    var slots: std.array_hash_map.Auto(Key, std.ArrayList([]const u8)) = .empty;
    var late: std.array_hash_map.Auto(u32, std.ArrayList([]const u8)) = .empty;
    var dels: std.AutoHashMap(u32, void) = .init(a);
    for (ops) |o| switch (o.kind) {
        .bdel => try dels.put(E[o.e].lit.id, {}),
        .bins => {
            const c: u8 = switch (o.slot.cont) {
                .b => 0,
                .F => 1,
                .P => 2,
                .in => unreachable,
            };
            const got = try slots.getOrPutValue(a, .{ .g = o.pos, .c = c, .sub = o.slot.sub }, .empty);
            try got.value_ptr.append(a, o.t);
        },
        .bput => {
            const got = try late.getOrPutValue(a, o.e, .empty);
            try got.value_ptr.append(a, o.t);
        },
        else => {},
    };

    // The elements each item of a container spans.
    const Span = struct { lo: u32, hi: u32 };
    const spanOf = struct {
        fn f(l: Lay, c: Cont, it: Item) ?Span {
            var s: ?Span = null;
            for (l.elems, 0..) |el, ei_| {
                const ei: u32 = @intCast(ei_);
                const hit = switch (it) {
                    .lit => |x| el == .lit and el.lit.cont == c and el.lit.id == x.id,
                    .inc => |ic| c == .b and el == .lit and el.lit.cont == ic,
                    .loop => |lp| c == .b and el == .row and el.row.lp == lp,
                };
                if (!hit) continue;
                s = if (s) |v| .{ .lo = @min(v.lo, ei), .hi = @max(v.hi, ei) } else .{ .lo = ei, .hi = ei };
            }
            return s;
        }
    }.f;

    var built: [3][]const Item = undefined;
    for ([_]Cont{ .b, .F, .P }) |c| {
        var list: std.ArrayList(Item) = .empty;
        switch (c) {
            .b => try list.appendSlice(a, lay.st.base),
            .F, .P => for (lay.st.cont(c)) |l| try list.append(a, .{ .lit = l }),
        }
        var o: std.ArrayList(Item) = .empty;
        var sg: u32 = 0;
        var sk: u32 = 0;
        const nm = struct {
            fn f(l: Lay, cont: Cont, g: u32) u32 {
                return if (cont == .b) l.empty_at[g] else 0;
            }
        }.f;
        const flush = struct {
            fn f(al: Allocator, l: Lay, cont: Cont, s: *const std.array_hash_map.Auto(Key, std.ArrayList([]const u8)), out: *std.ArrayList(Item), g_: *u32, k_: *u32, g: u32, k: u32) !void {
                const ccc: u8 = @intFromEnum(cont);
                while (g_.* < g or (g_.* == g and k_.* <= k)) {
                    if (s.get(.{ .g = g_.*, .c = ccc, .sub = @intCast(k_.*) })) |texts| {
                        for (texts.items) |t| try out.append(al, .{ .lit = .{ .id = newId(), .text = t } });
                    }
                    if (k_.* < nm(l, cont, g_.*)) {
                        k_.* += 1;
                    } else {
                        g_.* += 1;
                        k_.* = 0;
                    }
                }
            }
        }.f;
        for (list.items) |it| {
            if (spanOf(lay, c, it)) |sp| {
                try flush(a, lay, c, &slots, &o, &sg, &sk, sp.lo, nm(lay, c, sp.lo));
                switch (it) {
                    .lit => |l| {
                        if (late.get(sp.lo)) |texts| {
                            for (texts.items) |t| try o.append(a, .{ .lit = .{ .id = newId(), .text = t } });
                        }
                        if (!dels.contains(l.id)) try o.append(a, it);
                    },
                    else => try o.append(a, it),
                }
                sg = sp.hi + 1;
                sk = 0;
            } else {
                const gap = lay.empty_gap[it.loop].?;
                try flush(a, lay, c, &slots, &o, &sg, &sk, gap.g, gap.k);
                try o.append(a, it);
                sg = gap.g;
                sk = gap.k + 1;
            }
        }
        const n: u32 = @intCast(E.len);
        try flush(a, lay, c, &slots, &o, &sg, &sk, n, nm(lay, c, n));
        built[@intFromEnum(c)] = try o.toOwnedSlice(a);
    }

    const data = try a.alloc([]const Row, lay.st.data.len);
    for (lay.st.data, 0..) |rows, d_| {
        const d: u8 = @intCast(d_);
        var o: std.ArrayList(Row) = .empty;
        for (0..rows.len + 1) |pos| {
            for (ops) |x| {
                if (x.kind == .rowins and x.d == d and x.pos == pos) try o.append(a, .{ .rid = newId(), .v = x.t });
            }
            if (pos == rows.len) break;
            const r = rows[pos];
            var deleted = false;
            var v = r.v;
            for (ops) |x| {
                if (x.d != d or x.rid != r.rid) continue;
                if (x.kind == .rowdel) deleted = true;
                if (x.kind == .rowset) v = x.t;
            }
            if (!deleted) try o.append(a, .{ .rid = r.rid, .v = v });
        }
        data[d] = try o.toOwnedSlice(a);
    }
    return .{ .base = built[0], .f = try litsOf(a, built[1]), .p = try litsOf(a, built[2]), .data = data };
}

fn litsOf(a: Allocator, items: []const Item) ![]const Lit {
    const out = try a.alloc(Lit, items.len);
    for (items, 0..) |it, i| out[i] = it.lit;
    return out;
}

/// The live lines a combination leaves, or null when an unrepresentable
/// edit targets a row the representable part removed.
fn applyInterp(a: Allocator, lay: Lay, combo: []const Op) !?[]const []const u8 {
    const cfg = lay.cfg;
    const st = try applySrc(a, lay, try atoms(a, combo));
    const r = try render(a, cfg, st);
    const K3 = struct { lp: u8, rid: u32, pi: u8 };
    var mod: std.AutoHashMap(K3, []const u8) = .init(a);
    var drop: std.AutoHashMap(K3, void) = .init(a);
    var after: std.array_hash_map.Auto(K3, std.ArrayList([]const u8)) = .empty;
    const Before = struct { t: []const u8, prev: u32 };
    var before: std.array_hash_map.Auto([2]u32, std.ArrayList(Before)) = .empty;
    for (combo) |o| {
        switch (o.kind) {
            .rowbad => {
                const e = lay.elems[o.e].row;
                try mod.put(.{ .lp = e.lp, .rid = e.rid, .pi = cfg.captureIndex(e.lp) }, o.t);
            },
            .crep => {
                const e = lay.elems[o.e].row;
                try mod.put(.{ .lp = e.lp, .rid = e.rid, .pi = o.pi }, o.t);
            },
            .cdel => {
                const e = lay.elems[o.e].row;
                try drop.put(.{ .lp = e.lp, .rid = e.rid, .pi = o.pi }, {});
            },
            .xdel => {
                const e = lay.elems[o.e].row;
                try drop.put(.{ .lp = e.lp, .rid = e.rid, .pi = cfg.captureIndex(e.lp) }, {});
            },
            .pins => {
                const e = lay.elems[o.e].row;
                const got = try after.getOrPutValue(a, .{ .lp = e.lp, .rid = e.rid, .pi = o.pi }, .empty);
                try got.value_ptr.append(a, o.t);
            },
            .bins => if (o.slot.cont == .in) {
                const en = lay.elems[o.pos].row;
                const ep = lay.elems[o.pos - 1].row;
                const got = try before.getOrPutValue(a, .{ en.lp, en.rid }, .empty);
                try got.value_ptr.append(a, .{ .t = o.t, .prev = ep.rid });
            },
            else => {},
        }
    }
    // Each rendered row and its last line.
    var present: std.AutoHashMap([2]u32, u8) = .init(a);
    for (r) |l| switch (l.tag) {
        .row => |t| try present.put(.{ t.lp, t.rid }, t.pi),
        .lit => {},
    };
    var mit = mod.keyIterator();
    while (mit.next()) |k| if (!present.contains(.{ k.lp, k.rid })) return null;
    var dit = drop.keyIterator();
    while (dit.next()) |k| if (!present.contains(.{ k.lp, k.rid })) return null;
    for (after.keys()) |k| if (!present.contains(.{ k.lp, k.rid })) return null;
    // An insertion before a row the edit removed follows the row before it.
    for (before.keys(), before.values()) |k, v| {
        if (present.contains(k)) continue;
        for (v.items) |b| {
            const last = present.get(.{ k[0], b.prev }) orelse return null;
            const got = try after.getOrPutValue(a, .{ .lp = @intCast(k[0]), .rid = b.prev, .pi = last }, .empty);
            try got.value_ptr.append(a, b.t);
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (r) |l| switch (l.tag) {
        .row => |t| {
            const k3: K3 = .{ .lp = t.lp, .rid = t.rid, .pi = t.pi };
            if (t.pi == 0) {
                if (before.get(.{ t.lp, t.rid })) |v| for (v.items) |b| try out.append(a, b.t);
            }
            if (!drop.contains(k3)) try out.append(a, mod.get(k3) orelse l.text);
            if (after.get(k3)) |v| try out.appendSlice(a, v.items);
        },
        .lit => try out.append(a, l.text),
    };
    return try out.toOwnedSlice(a);
}

/// A source state as the oracle compares it: literal texts in order within
/// each source, directives in place, and rows by identity and value.
const Canon = struct {
    lits: []const u8,
    data: []const u8,
    repo: std.StringHashMap(u32),
    private: std.StringHashMap(u32),

    fn full(c: Canon, a: Allocator) ![]const u8 {
        return std.mem.concat(a, u8, &.{ c.lits, "|", c.data });
    }
};

fn canon(a: Allocator, st: State) !Canon {
    var lits: std.ArrayList(u8) = .empty;
    var repo: std.StringHashMap(u32) = .init(a);
    var private: std.StringHashMap(u32) = .init(a);
    for (st.base) |it| switch (it) {
        .lit => |l| {
            try lits.print(a, "L{s};", .{l.text});
            (try repo.getOrPutValue(l.text, 0)).value_ptr.* += 1;
        },
        .inc => |c| try lits.print(a, "I{s};", .{@tagName(c)}),
        .loop => |lp| try lits.print(a, "M{d};", .{lp}),
    };
    try lits.appendSlice(a, "|F");
    for (st.f) |l| {
        try lits.print(a, "{s};", .{l.text});
        (try repo.getOrPutValue(l.text, 0)).value_ptr.* += 1;
    }
    try lits.appendSlice(a, "|P");
    for (st.p) |l| {
        try lits.print(a, "{s};", .{l.text});
        (try private.getOrPutValue(l.text, 0)).value_ptr.* += 1;
    }
    var data: std.ArrayList(u8) = .empty;
    for (st.data, 0..) |rows, d| {
        try data.print(a, "D{d}:", .{d});
        for (rows) |r| try data.print(a, "{d}={s},", .{ r.rid, r.v });
    }
    return .{ .lits = try lits.toOwnedSlice(a), .data = try data.toOwnedSlice(a), .repo = repo, .private = private };
}

/// Every state a subset of a combination's representable operations leaves.
fn subsetStates(a: Allocator, lay: Lay, combo: []const Op, into: *std.ArrayList(Canon)) !void {
    const at = try atoms(a, combo);
    const n = at.len;
    var mask: usize = 0;
    while (mask < (@as(usize, 1) << @intCast(n))) : (mask += 1) {
        var sub: std.ArrayList(Op) = .empty;
        for (at, 0..) |o, i| {
            if (mask & (@as(usize, 1) << @intCast(i)) != 0) try sub.append(a, o);
        }
        try into.append(a, try canon(a, try applySrc(a, lay, sub.items)));
    }
}

// Files the layout is written to.

const base_rel = ".hosts";
const include_line = "# mox: include \"f.sh\"";
const region_open = "# mox: replace from \"profile\"";
/// A row gate every row passes on the pinned machine.
const nested_gate = "# mox: when os=darwin";

fn loopDirective(a: Allocator, cfg: Cfg, lp: usize) ![]const u8 {
    const l = cfg.loops[lp];
    var s: std.ArrayList(u8) = .empty;
    try s.print(a, "# mox: for entry in \"data/d{d}.toml\"", .{l.ds});
    if (l.where) |w| {
        try s.appendSlice(a, " where ");
        for (w, 0..) |v, i| {
            if (i > 0) try s.appendSlice(a, " or ");
            try s.print(a, "entry.v = \"{s}\"", .{v});
        }
    }
    return s.toOwnedSlice(a);
}

fn baseText(a: Allocator, cfg: Cfg, st: State) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (st.base) |it| switch (it) {
        .lit => |l| try s.print(a, "{s}\n", .{l.text}),
        .inc => |c| switch (c) {
            .F => try s.print(a, "{s}\n", .{include_line}),
            .P => try s.print(a, "{s}\nfallback\n# mox: end\n", .{region_open}),
            .b => unreachable,
        },
        .loop => |lp| {
            try s.print(a, "{s}\n", .{try loopDirective(a, cfg, lp)});
            if (cfg.loops[lp].nested) try s.appendSlice(a, nested_gate ++ "\n");
            for (cfg.loops[lp].parts) |p| switch (p) {
                .capture => try s.print(a, "{s}<entry.v>\n", .{cfg.loops[lp].pre}),
                .constant => |k| try s.print(a, "{s}\n", .{k}),
            };
            if (cfg.loops[lp].nested) try s.appendSlice(a, "# mox: end\n");
            try s.appendSlice(a, "# mox: end\n");
        },
    };
    return s.toOwnedSlice(a);
}

fn linesText(a: Allocator, lines: anytype) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (lines) |l| try s.print(a, "{s}\n", .{if (@TypeOf(l) == Lit) l.text else l});
    return s.toOwnedSlice(a);
}

fn dataText(a: Allocator, d: usize, rows: []const Row) ![]const u8 {
    if (rows.len == 0) return std.fmt.allocPrint(a, "d{d} = []\n", .{d});
    var s: std.ArrayList(u8) = .empty;
    for (rows, 0..) |r, i| {
        if (i > 0) try s.appendSlice(a, "\n");
        try s.print(a, "[[d{d}]]\nid = {d}\nv = \"", .{ d, r.rid });
        for (r.v) |ch| {
            if (ch == '\n') try s.appendSlice(a, "\\n") else try s.append(a, ch);
        }
        try s.appendSlice(a, "\"\n");
    }
    return s.toOwnedSlice(a);
}

fn splitText(a: Allocator, s: []const u8) ![]const []const u8 {
    return mox.diff.lines.splitLines(a, s);
}

/// The source state the files hold, in the layout's terms.
fn readState(a: Allocator, io: Io, h: testutil.Harness, lay: Lay) !State {
    const base = try splitText(a, try readOr(a, io, try h.srcOf(base_rel)));
    var loops: std.ArrayList(u8) = .empty;
    for (lay.st.base) |it| if (it == .loop) try loops.append(a, it.loop);
    var items: std.ArrayList(Item) = .empty;
    var nth: usize = 0;
    var i: usize = 0;
    while (i < base.len) : (i += 1) {
        const line = base[i];
        if (std.mem.startsWith(u8, line, "# mox: for ")) {
            const lp = loops.items[nth];
            var ends: usize = if (lay.cfg.loops[lp].nested) 2 else 1;
            while (true) : (i += 1) {
                if (!std.mem.eql(u8, base[i], "# mox: end")) continue;
                ends -= 1;
                if (ends == 0) break;
            }
            try items.append(a, .{ .loop = lp });
            nth += 1;
        } else if (std.mem.eql(u8, line, include_line)) {
            try items.append(a, .{ .inc = .F });
        } else if (std.mem.eql(u8, line, region_open)) {
            while (!std.mem.eql(u8, base[i], "# mox: end")) i += 1;
            try items.append(a, .{ .inc = .P });
        } else try items.append(a, .{ .lit = .{ .id = 0, .text = line } });
    }
    const f = try splitText(a, try readOr(a, io, try h.srcOf(base_rel ++ ".d/f.sh")));
    const p = try splitText(a, try readOr(a, io, try std.fs.path.join(a, &.{ h.state, "private", base_rel ++ ".d", "profile", "personal.hosts" })));
    const data = try a.alloc([]const Row, lay.st.data.len);
    for (0..data.len) |d| {
        const text = try readOr(a, io, try std.fs.path.join(a, &.{ h.repo, "data", try std.fmt.allocPrint(a, "d{d}.toml", .{d}) }));
        var rows: std.ArrayList(Row) = .empty;
        var id: u32 = 0;
        for (try splitText(a, text)) |line| {
            if (std.mem.startsWith(u8, line, "id = ")) id = try std.fmt.parseInt(u32, line[5..], 10);
            if (std.mem.startsWith(u8, line, "v = \"")) {
                const v = try std.mem.replaceOwned(u8, a, line[5 .. line.len - 1], "\\n", "\n");
                try rows.append(a, .{ .rid = id, .v = v });
            }
        }
        data[d] = try rows.toOwnedSlice(a);
    }
    const flits = try a.alloc(Lit, f.len);
    for (f, 0..) |t, k| flits[k] = .{ .id = 0, .text = t };
    const plits = try a.alloc(Lit, p.len);
    for (p, 0..) |t, k| plits[k] = .{ .id = 0, .text = t };
    return .{ .base = try items.toOwnedSlice(a), .f = flits, .p = plits, .data = data };
}

fn readOr(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => e,
    };
}

// The sweep.

/// How a commit is run: `--yes`; interactively, taking every default (each
/// route accepted, each split declined); interactively, splitting whatever
/// may be split and accepting every route; or, taking every default, with
/// the file's applied record removed, so it is routed as a first contact
/// against a fresh compose.
const Mode = enum { yes, decline_splits, accept_splits, first_contact };

const Sweep = struct {
    cfg: Cfg,
    k: usize,
    maxlit: usize,
    conts: []const Cont,
    maxrows: usize,
    maxn: usize,
    modes: []const Mode,
    /// Only every `stride`-th edit, counted across the sweep, is run.
    stride: usize = 1,
};

const Budget = struct {
    runs: usize = 0,
    max_runs: usize,
    started: Io.Timestamp,
    max_ms: i64,
    io: Io,

    fn charge(b: *Budget) !void {
        b.runs += 1;
        if (b.runs > b.max_runs) return error.RealignSweepExceededItsRunBound;
        if (b.started.durationTo(Io.Clock.awake.now(b.io)).toMilliseconds() > b.max_ms) return error.RealignSweepExceededItsTimeBound;
    }
};

fn shapes(a: Allocator, cfg: Cfg, maxlit: usize, conts: []const Cont) ![]const []const u8 {
    var alpha: std.ArrayList(u8) = .empty;
    try alpha.append(a, 'b');
    for (conts) |c| try alpha.append(a, @tagName(c)[0]);
    for (0..cfg.loops.len) |l| try alpha.append(a, '0' + @as(u8, @intCast(l)));
    var out: std.ArrayList([]const u8) = .empty;
    for (0..maxlit + 1) |nlit| {
        const n = nlit + cfg.loops.len;
        if (n == 0) continue;
        const seq = try a.alloc(u8, n);
        var total: usize = 1;
        for (0..n) |_| total *= alpha.items.len;
        for (0..total) |code| {
            var c = code;
            for (0..n) |i| {
                seq[i] = alpha.items[c % alpha.items.len];
                c /= alpha.items.len;
            }
            var ok = true;
            for (0..cfg.loops.len) |l| {
                if (std.mem.count(u8, seq, &.{'0' + @as(u8, @intCast(l))}) != 1) ok = false;
            }
            for (conts) |ct| {
                const ch = @tagName(ct)[0];
                const first = std.mem.indexOfScalar(u8, seq, ch) orelse continue;
                const last = std.mem.lastIndexOfScalar(u8, seq, ch).?;
                if (last - first + 1 != std.mem.count(u8, seq, &.{ch})) ok = false;
            }
            if (ok) try out.append(a, try a.dupe(u8, seq));
        }
    }
    return out.toOwnedSlice(a);
}

fn layoutsOf(a: Allocator, cfg: Cfg, seq: []const u8, maxrows: usize, maxn: usize) ![]State {
    var out: std.ArrayList(State) = .empty;
    var lit_pos: std.ArrayList(usize) = .empty;
    for (seq, 0..) |ch, i| if (ch == 'b' or ch == 'F' or ch == 'P') try lit_pos.append(a, i);
    const nds = cfg.doms.len;
    var nr = try a.alloc(usize, nds);
    var nr_code: usize = 0;
    var nr_total: usize = 1;
    for (0..nds) |_| nr_total *= maxrows + 1;
    while (nr_code < nr_total) : (nr_code += 1) {
        var c = nr_code;
        var slots: usize = 0;
        for (0..nds) |d| {
            nr[d] = c % (maxrows + 1);
            c /= maxrows + 1;
            slots += nr[d];
        }
        var lt_total: usize = 1;
        for (lit_pos.items) |_| lt_total *= cfg.texts.len;
        for (0..lt_total) |lt_code| {
            var rv_total: usize = 1;
            for (0..nds) |d| {
                for (0..nr[d]) |_| rv_total *= cfg.doms[d].len;
            }
            for (0..rv_total) |rv_code| {
                var rc = rv_code;
                const data = try a.alloc([]const Row, nds);
                for (0..nds) |d| {
                    const rows = try a.alloc(Row, nr[d]);
                    for (0..nr[d]) |k| {
                        rows[k] = .{ .rid = @intCast(k), .v = cfg.doms[d][rc % cfg.doms[d].len] };
                        rc /= cfg.doms[d].len;
                    }
                    data[d] = rows;
                }
                var nel: usize = lit_pos.items.len;
                for (0..cfg.loops.len) |l| {
                    for (data[cfg.loops[l].ds]) |r| {
                        if (cfg.passes(l, r.v)) nel += 1;
                    }
                }
                if (nel == 0 or nel > maxn) continue;
                var base: std.ArrayList(Item) = .empty;
                var f: std.ArrayList(Lit) = .empty;
                var p: std.ArrayList(Lit) = .empty;
                var tc = lt_code;
                var nid: u32 = 0;
                for (seq) |ch| switch (ch) {
                    'b', 'F', 'P' => {
                        const text = cfg.texts[tc % cfg.texts.len];
                        tc /= cfg.texts.len;
                        const lit: Lit = .{ .id = nid, .text = text };
                        nid += 1;
                        switch (ch) {
                            'b' => try base.append(a, .{ .lit = lit }),
                            'F' => {
                                if (f.items.len == 0) try base.append(a, .{ .inc = .F });
                                try f.append(a, lit);
                            },
                            else => {
                                if (p.items.len == 0) try base.append(a, .{ .inc = .P });
                                try p.append(a, lit);
                            },
                        }
                    },
                    else => try base.append(a, .{ .loop = ch - '0' }),
                };
                try out.append(a, .{ .base = try base.toOwnedSlice(a), .f = try f.toOwnedSlice(a), .p = try p.toOwnedSlice(a), .data = data });
            }
        }
    }
    return out.toOwnedSlice(a);
}

const Group = struct { size: usize, mins: std.ArrayList([]const Op) };

const Collect = struct {
    a: Allocator,
    /// Holds one interpretation's work, reset for each.
    scratch: *std.heap.ArenaAllocator,
    lay: Lay,
    groups: *std.array_hash_map.String(Group),

    fn add(c: *const Collect, combo: []const Op) anyerror!void {
        _ = c.scratch.reset(.retain_capacity);
        const sa = c.scratch.allocator();
        const b = (try applyInterp(sa, c.lay, combo)) orelse return;
        if (b.len == c.lay.a.len) {
            var same = true;
            for (b, c.lay.a) |x, y| {
                if (!std.mem.eql(u8, x, y)) same = false;
            }
            if (same) return;
        }
        const key = try linesText(sa, b);
        const got = try c.groups.getOrPut(c.a, key);
        if (!got.found_existing) got.key_ptr.* = try c.a.dupe(u8, key);
        if (!got.found_existing or combo.len < got.value_ptr.size) {
            got.value_ptr.* = .{ .size = combo.len, .mins = .empty };
        }
        if (combo.len == got.value_ptr.size) try got.value_ptr.mins.append(c.a, try c.a.dupe(Op, combo));
    }
};

const Harm = error{RealignHarm};

fn describe(a: Allocator, cfg: Cfg, lay: Lay, live: []const u8, mode: Mode, got: []const u8, res: testutil.RunResult) ![]const u8 {
    return std.fmt.allocPrint(a, "cfg {s}, mode {s}\n--- source\n{s}--- fragment\n{s}--- private\n{s}--- data\n{s}{s}--- baseline\n{s}--- live\n{s}--- state after commit\n{s}\n--- stdout\n{s}--- stderr\n{s}", .{
        cfg.name,
        @tagName(mode),
        try baseText(a, cfg, lay.st),
        try linesText(a, lay.st.f),
        try linesText(a, lay.st.p),
        if (lay.st.data.len > 0) try dataText(a, 0, lay.st.data[0]) else "",
        if (lay.st.data.len > 1) try dataText(a, 1, lay.st.data[1]) else "",
        try linesText(a, lay.a),
        live,
        got,
        res.out,
        res.err,
    });
}

fn runLayout(gpa: Allocator, io: Io, sw: Sweep, st: State, budget: *Budget, seen: *usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = sw.cfg;
    const lay = try Lay.init(a, cfg, st);

    var groups: std.array_hash_map.String(Group) = .empty;
    var gen_scratch = std.heap.ArenaAllocator.init(gpa);
    defer gen_scratch.deinit();
    var add_scratch = std.heap.ArenaAllocator.init(gpa);
    defer add_scratch.deinit();
    const collect: Collect = .{ .a = a, .scratch = &add_scratch, .lay = lay, .groups = &groups };
    try genCombos(&gen_scratch, lay, try opsFor(a, lay), sw.k, &collect, Collect.add);
    // The edits of this layout the stride selects.
    var picked: std.ArrayList(usize) = .empty;
    for (0..groups.count()) |gi| {
        if ((seen.* + gi) % sw.stride == 0) try picked.append(a, gi);
    }
    seen.* += groups.count();
    if (picked.items.len == 0) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.createDirPath(io, "repo/data");
    const base = try baseText(a, cfg, st);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/" ++ base_rel, .data = base });
    if (st.f.len > 0) {
        try tmp.dir.createDirPath(io, "repo/src/" ++ base_rel ++ ".d");
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/" ++ base_rel ++ ".d/f.sh", .data = try linesText(a, st.f) });
    }
    if (st.p.len > 0) {
        try tmp.dir.createDirPath(io, "state/private/" ++ base_rel ++ ".d/profile");
        try tmp.dir.writeFile(io, .{ .sub_path = "state/private/" ++ base_rel, .data = "top\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "state/private/" ++ base_rel ++ ".d/profile/personal.hosts", .data = try linesText(a, st.p) });
        try tmp.dir.createDirPath(io, "home/.config/mox");
        try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/mox/facts.toml", .data = "profile = \"personal\"\n" });
    }
    for (st.data, 0..) |rows, d| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "repo/data/d{d}.toml", .{d}), .data = try dataText(a, d, rows) });
    }
    const h = try testutil.setup(a, io, &tmp, .{ .os = "darwin" });
    const applied = try h.run(&.{ "mox", "apply" });
    const live_path = try h.liveOf(base_rel);
    const want = try linesText(a, lay.a);
    const got_live = try readOr(a, io, live_path);
    if (applied.rc != 0 or !std.mem.eql(u8, want, got_live)) {
        std.debug.print("layout does not apply as modelled (rc {d}):\n{s}--- want\n{s}--- got\n{s}{s}", .{ applied.rc, base, want, got_live, applied.err });
        return error.RealignLayoutMismatch;
    }
    const init_canon = try canon(a, lay.st);
    const read_canon = try canon(a, try readState(a, io, h, lay));
    if (!std.mem.eql(u8, try init_canon.full(a), try read_canon.full(a))) {
        std.debug.print("layout does not read back as modelled:\n{s}\n{s}\n", .{ try init_canon.full(a), try read_canon.full(a) });
        return error.RealignLayoutMismatch;
    }
    const saved = try snapshot(a, io, h.root);

    // Each edit's oracle and each commit run are scoped to their own arena.
    var group_arena = std.heap.ArenaAllocator.init(gpa);
    defer group_arena.deinit();
    var run_arena = std.heap.ArenaAllocator.init(gpa);
    defer run_arena.deinit();
    for (picked.items) |gi| {
        _ = group_arena.reset(.retain_capacity);
        const ga = group_arena.allocator();
        const live = groups.keys()[gi];
        const g = groups.values()[gi];
        var okx: std.ArrayList(Canon) = .empty;
        for (g.mins.items) |c| try subsetStates(ga, lay, c, &okx);
        var ok_full: std.StringHashMap(void) = .init(ga);
        var ok_data: std.StringHashMap(void) = .init(ga);
        for (okx.items) |c| {
            try ok_full.put(try c.full(ga), {});
            try ok_data.put(c.data, {});
        }
        var row_free = false;
        for (g.mins.items) |c| {
            var any_row = false;
            for (c) |o| any_row = any_row or o.isRow();
            if (!any_row) row_free = true;
        }
        for (sw.modes) |mode| {
            _ = run_arena.reset(.retain_capacity);
            const ra = run_arena.allocator();
            var hr = h;
            hr.a = ra;
            try budget.charge();
            if (mode == .first_contact) {
                for ([_][]const u8{ "applied", "applied-content" }) |dir| {
                    try Io.Dir.cwd().deleteTree(io, try std.fs.path.join(ra, &.{ h.state, dir }));
                }
            }
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live });
            const res = switch (mode) {
                .yes => try hr.run(&.{ "mox", "commit", "--yes", "--color=never" }),
                .decline_splits, .first_contact => try hr.runWithInput(&.{ "mox", "commit", "--color=never" }, "\n" ** 64),
                // `x` splits, `y` accepts, `1` keeps a shared edit universal; each
                // prompt skips the answers it does not take.
                .accept_splits => try hr.runWithInput(&.{ "mox", "commit", "--color=never" }, "x\ny\n1\n" ** 64),
            };
            const now_state = try readState(ra, io, hr, lay);
            const now = try canon(ra, now_state);
            const now_full = try now.full(ra);
            var why: ?[]const u8 = null;
            if (res.rc == 2 or std.mem.indexOf(u8, res.out, "aborted") != null) why = "the run aborted or failed";
            if (sw.k <= 2 and mode != .accept_splits) {
                if (!ok_full.contains(now_full)) why = "the sources are not a subset of any minimum-operation interpretation";
                if (row_free and !std.mem.eql(u8, now.data, init_canon.data)) why = "a row was written where an interpretation writes no row";
            } else if (!ok_data.contains(now.data)) why = "row data is not an interpretation's";
            if (movedLine(now.repo, okx.items, .repo) or movedLine(now.private, okx.items, .private)) why = "a source holds more copies of a line than any interpretation leaves there";
            if (mode == .accept_splits) {
                if (try pieceFault(ra, lay, now_state, res.out)) |f| why = f;
            }
            if (!try othersIntact(ra, io, hr, saved)) why = "a file other than the layout's sources changed";
            if (why) |w| {
                std.debug.print("realignment harm: {s}\n{s}\n", .{ w, try describe(ra, cfg, lay, live, mode, now_full, res) });
                return Harm.RealignHarm;
            }
            try restore(ra, io, h.root, saved);
        }
    }
}

/// Why a routed line edit of an interactive run left its one source, or
/// null: each hunk header naming a base, fragment or private route (every
/// one accepted in these runs) must delete one run of that source's lines,
/// no directive inside it, and its added lines must be in that source
/// unless the run left the source as it was.
fn pieceFault(a: Allocator, lay: Lay, now: State, out: []const u8) !?[]const u8 {
    const lines = try splitText(a, out);
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const at = std.mem.indexOf(u8, lines[i], "  ->  ") orelse continue;
        if (std.mem.indexOf(u8, lines[i][0..at], " hunk ") == null) continue;
        const route = lines[i][at + 6 ..];
        const cont: Cont = if (std.mem.eql(u8, route, "src/" ++ base_rel ++ " (base)"))
            .b
        else if (std.mem.startsWith(u8, route, "fragment "))
            .F
        else if (std.mem.startsWith(u8, route, "private "))
            .P
        else
            continue;
        var dels: std.ArrayList([]const u8) = .empty;
        var adds: std.ArrayList([]const u8) = .empty;
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            if (std.mem.startsWith(u8, lines[j], "    - ")) {
                try dels.append(a, lines[j][6..]);
            } else if (std.mem.startsWith(u8, lines[j], "    + ")) {
                try adds.append(a, lines[j][6..]);
            } else break;
        }
        const before = try contLits(a, lay.st, cont);
        if (dels.items.len > 0 and !hasRun(before, dels.items)) return "a routed hunk deletes lines that are not one run of one source";
        const after = try contLits(a, now, cont);
        if (sameTexts(before, after)) continue;
        for (adds.items) |t| {
            var want: usize = 0;
            for (adds.items) |u| {
                if (std.mem.eql(u8, u, t)) want += 1;
            }
            var have: usize = 0;
            for (after) |u| {
                if (u != null and std.mem.eql(u8, u.?, t)) have += 1;
            }
            if (have < want) return "a routed hunk's added lines are not in its source";
        }
    }
    return null;
}

/// A source's lines in order, a directive of the base as null.
fn contLits(a: Allocator, st: State, c: Cont) ![]const ?[]const u8 {
    var out: std.ArrayList(?[]const u8) = .empty;
    switch (c) {
        .b => for (st.base) |it| try out.append(a, if (it == .lit) it.lit.text else null),
        .F, .P => for (st.cont(c)) |l| try out.append(a, l.text),
    }
    return out.toOwnedSlice(a);
}

fn hasRun(hay: []const ?[]const u8, run: []const []const u8) bool {
    if (run.len > hay.len) return false;
    outer: for (0..hay.len - run.len + 1) |k| {
        for (run, 0..) |t, m| {
            const h = hay[k + m] orelse continue :outer;
            if (!std.mem.eql(u8, h, t)) continue :outer;
        }
        return true;
    }
    return false;
}

fn sameTexts(x: []const ?[]const u8, y: []const ?[]const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if ((p == null) != (q == null)) return false;
        if (p != null and !std.mem.eql(u8, p.?, q.?)) return false;
    }
    return true;
}

/// Whether every file under the repo and the private layer other than the
/// layout's sources is as the apply left it, and no file was added there.
fn othersIntact(a: Allocator, io: Io, h: testutil.Harness, saved: std.StringHashMap([]const u8)) !bool {
    const sources = [_][]const u8{
        try h.srcOf(base_rel),
        try h.srcOf(base_rel ++ ".d/f.sh"),
        try std.fs.path.join(a, &.{ h.state, "private", base_rel ++ ".d", "profile", "personal.hosts" }),
    };
    const data_dir = try std.fs.path.join(a, &.{ h.repo, "data" });
    const private_dir = try std.fs.path.join(a, &.{ h.state, "private" });
    const isSource = struct {
        fn f(srcs: []const []const u8, dd: []const u8, path: []const u8) bool {
            if (std.mem.startsWith(u8, path, dd)) return true;
            for (srcs) |x| {
                if (std.mem.eql(u8, x, path)) return true;
            }
            return false;
        }
    }.f;
    var seen: usize = 0;
    for ([_][]const u8{ h.repo, private_dir }) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const path = try std.fs.path.join(a, &.{ dir_path, e.path });
            if (isSource(&sources, data_dir, path)) continue;
            const want = saved.get(path) orelse return false;
            if (!std.mem.eql(u8, want, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 22)))) return false;
            seen += 1;
        }
    }
    var expected: usize = 0;
    var it = saved.keyIterator();
    while (it.next()) |k| {
        const in_scope = std.mem.startsWith(u8, k.*, h.repo) or std.mem.startsWith(u8, k.*, private_dir);
        if (in_scope and !isSource(&sources, data_dir, k.*)) expected += 1;
    }
    return seen == expected;
}

fn movedLine(counts: std.StringHashMap(u32), okx: []const Canon, side: enum { repo, private }) bool {
    var it = counts.iterator();
    while (it.next()) |e| {
        var most: u32 = 0;
        for (okx) |c| {
            const m = if (side == .repo) c.repo else c.private;
            most = @max(most, m.get(e.key_ptr.*) orelse 0);
        }
        if (e.value_ptr.* > most) return true;
    }
    return false;
}

/// Every file under the sources and the state directory (the private layer
/// included) as the apply left them, by path.
fn snapshot(a: Allocator, io: Io, root: []const u8) !std.StringHashMap([]const u8) {
    var out: std.StringHashMap([]const u8) = .init(a);
    for ([_][]const u8{ "repo", "state" }) |top| {
        const dir_path = try std.fs.path.join(a, &.{ root, top });
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const path = try std.fs.path.join(a, &.{ dir_path, e.path });
            try out.put(path, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 22)));
        }
    }
    return out;
}

/// Put back what a commit changed: rewrite each file whose bytes differ,
/// delete each file the apply did not leave.
fn restore(a: Allocator, io: Io, root: []const u8, saved: std.StringHashMap([]const u8)) !void {
    var present: std.StringHashMap(void) = .init(a);
    for ([_][]const u8{ "repo", "state" }) |top| {
        const dir_path = try std.fs.path.join(a, &.{ root, top });
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const path = try std.fs.path.join(a, &.{ dir_path, e.path });
            const want = saved.get(path) orelse {
                try Io.Dir.cwd().deleteFile(io, path);
                continue;
            };
            try present.put(path, {});
            const now = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 22));
            if (!std.mem.eql(u8, now, want)) try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = want });
        }
    }
    var it = saved.iterator();
    while (it.next()) |e| {
        if (present.contains(e.key_ptr.*)) continue;
        if (std.fs.path.dirname(e.key_ptr.*)) |d| try Io.Dir.cwd().createDirPath(io, d);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = e.key_ptr.*, .data = e.value_ptr.* });
    }
}

/// A share of a sweep's layouts, `MOX_REALIGN_SHARD=<i>/<n>` taking every
/// n-th from the i-th, so the full sweep can run as parallel processes.
const Shard = struct { i: usize = 0, n: usize = 1 };

fn shardOf(a: Allocator) !Shard {
    const v = std.testing.environ.getAlloc(a, "MOX_REALIGN_SHARD") catch return .{};
    const slash = std.mem.indexOfScalar(u8, v, '/') orelse return error.BadRealignShard;
    const sh: Shard = .{ .i = try std.fmt.parseInt(usize, v[0..slash], 10), .n = try std.fmt.parseInt(usize, v[slash + 1 ..], 10) };
    if (sh.n == 0 or sh.i >= sh.n) return error.BadRealignShard;
    return sh;
}

fn runSweep(sw: Sweep, budget: *Budget, shard: Shard) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var seen: usize = 0;
    var index: usize = 0;
    for (try shapes(a, sw.cfg, sw.maxlit, sw.conts)) |seq| {
        var la = std.heap.ArenaAllocator.init(gpa);
        defer la.deinit();
        for (try layoutsOf(la.allocator(), sw.cfg, seq, sw.maxrows, sw.maxn)) |st| {
            defer index += 1;
            if (index % shard.n != shard.i) continue;
            try runLayout(gpa, io, sw, st, budget, &seen);
        }
    }
}

/// Ends the process when the sweep outlives its time bound, so a commit run
/// that never returns fails the test instead of hanging it.
fn watchdog(io: Io, started: Io.Timestamp, max_ms: i64, done: *std.atomic.Value(bool)) void {
    while (!done.load(.acquire)) {
        io.sleep(.fromMilliseconds(500), .awake) catch return;
        if (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > max_ms + 30_000) {
            std.debug.print("commit realignment sweep exceeded its time bound inside one commit run\n", .{});
            std.process.exit(1);
        }
    }
}

// Configurations. A capture line is `pre` and the row's value; `p` fits no
// loop; `k` is a multi-line template's constant line. A data source's values
// are every text's value that some loop over it splits, since commit writes
// any value the template splits.

const cap: Part = .capture;
const xy: []const []const u8 = &.{ "x", "y" };
const yz: []const []const u8 = &.{ "y", "z" };

const one: Cfg = .{ .name = "one", .loops = &.{.{ .parts = &.{cap}, .pre = "h ", .ds = 0 }}, .doms = &.{xy}, .texts = &.{ "h x", "h y", "p" } };
const bare: Cfg = .{ .name = "bare", .loops = &.{.{ .parts = &.{cap}, .pre = "", .ds = 0 }}, .doms = &.{&.{ "p", "x", "y" }}, .texts = &.{ "x", "y", "p" } };
const ml_ck: Cfg = .{ .name = "ml_ck", .loops = &.{.{ .parts = &.{ cap, .{ .constant = "k" } }, .pre = "h ", .ds = 0 }}, .doms = &.{xy}, .texts = &.{ "h x", "h y", "k", "p" } };
const ml_kc: Cfg = .{ .name = "ml_kc", .loops = &.{.{ .parts = &.{ .{ .constant = "k" }, cap }, .pre = "h ", .ds = 0 }}, .doms = &.{xy}, .texts = &.{ "h x", "h y", "k", "p" } };
const two_same: Cfg = .{ .name = "two_same", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "h ", .ds = 1 } }, .doms = &.{ xy, xy }, .texts = &.{ "h x", "h y", "p" } };
const two_diff: Cfg = .{ .name = "two_diff", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "g ", .ds = 1 } }, .doms = &.{ xy, yz }, .texts = &.{ "h x", "h y", "g y", "g z", "p" } };
const shared: Cfg = .{ .name = "shared", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "a ", .ds = 0 } }, .doms = &.{xy}, .texts = &.{ "h x", "h y", "a x", "a y", "p" } };
const shared_same: Cfg = .{ .name = "shared_same", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "h ", .ds = 0 } }, .doms = &.{xy}, .texts = &.{ "h x", "h y", "p" } };
const shared_ml: Cfg = .{ .name = "shared_ml", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{ cap, .{ .constant = "k" } }, .pre = "a ", .ds = 0 } }, .doms = &.{xy}, .texts = &.{ "h x", "h y", "a x", "a y", "k", "p" } };
const where_other: Cfg = .{ .name = "where", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "a ", .ds = 0, .where = &.{"x"} } }, .doms = &.{xy}, .texts = &.{ "h x", "h y", "a x", "a y", "p" } };
const where_both: Cfg = .{ .name = "where_both", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0, .where = &.{ "x", "y" } }, .{ .parts = &.{cap}, .pre = "a ", .ds = 0, .where = &.{ "y", "z" } } }, .doms = &.{&.{ "x", "y", "z" }}, .texts = &.{ "h x", "h y", "h z", "a x", "a y", "a z", "p" } };
const where_one: Cfg = .{ .name = "where_one", .loops = &.{.{ .parts = &.{cap}, .pre = "h ", .ds = 0, .where = &.{"x"} }}, .doms = &.{xy}, .texts = &.{ "h x", "h y", "p" } };
const mlval: Cfg = .{ .name = "mlval", .loops = &.{.{ .parts = &.{cap}, .pre = "h ", .ds = 0 }}, .doms = &.{&.{ "x", "y", "y\nq" }}, .texts = &.{ "h x", "h y", "q", "p" } };
const nested: Cfg = .{ .name = "nested", .loops = &.{.{ .parts = &.{cap}, .pre = "h ", .ds = 0, .nested = true }}, .doms = &.{xy}, .texts = &.{ "h x", "h y", "p" } };
const nested_shared: Cfg = .{ .name = "nested_shared", .loops = &.{ .{ .parts = &.{cap}, .pre = "h ", .ds = 0 }, .{ .parts = &.{cap}, .pre = "a ", .ds = 0, .nested = true } }, .doms = &.{xy}, .texts = &.{ "h x", "h y", "a x", "a y", "p" } };
const noloop: Cfg = .{ .name = "noloop", .loops = &.{}, .doms = &.{}, .texts = &.{ "x", "y", "p" } };

const FP: []const Cont = &.{ .F, .P };
const P_only: []const Cont = &.{.P};
const none: []const Cont = &.{};
const yes_only: []const Mode = &.{.yes};
const all_modes: []const Mode = &.{ .yes, .decline_splits, .accept_splits, .first_contact };
const yes_split: []const Mode = &.{ .yes, .accept_splits };

/// The default suite's sample: every 8th to 24th edit of seven sweeps, one of
/// them in all four modes, about 3100 commit runs.
const slice_sweep = [_]Sweep{
    .{ .cfg = mlval, .k = 1, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 3, .modes = yes_split, .stride = 8 },
    .{ .cfg = nested, .k = 1, .maxlit = 1, .conts = FP, .maxrows = 1, .maxn = 3, .modes = yes_only, .stride = 8 },
    .{ .cfg = one, .k = 2, .maxlit = 1, .conts = FP, .maxrows = 1, .maxn = 2, .modes = all_modes, .stride = 12 },
    .{ .cfg = shared, .k = 1, .maxlit = 1, .conts = P_only, .maxrows = 1, .maxn = 3, .modes = yes_only, .stride = 12 },
    .{ .cfg = where_other, .k = 1, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 3, .modes = yes_only, .stride = 8 },
    .{ .cfg = ml_ck, .k = 1, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 3, .modes = yes_only, .stride = 8 },
    .{ .cfg = noloop, .k = 2, .maxlit = 2, .conts = FP, .maxrows = 0, .maxn = 3, .modes = yes_split, .stride = 24 },
};

/// `zig build test-realign`: every edit of each sweep. With 2 550 000
/// commit runs it is meant for `-Doptimize=ReleaseFast` and sharding.
const full_sweep = [_]Sweep{
    .{ .cfg = one, .k = 2, .maxlit = 1, .conts = FP, .maxrows = 2, .maxn = 4, .modes = all_modes },
    .{ .cfg = one, .k = 2, .maxlit = 2, .conts = FP, .maxrows = 1, .maxn = 3, .modes = yes_split },
    .{ .cfg = one, .k = 1, .maxlit = 2, .conts = FP, .maxrows = 3, .maxn = 4, .modes = yes_split },
    .{ .cfg = bare, .k = 2, .maxlit = 2, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = ml_ck, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = ml_kc, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = two_same, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_only },
    .{ .cfg = two_diff, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 3, .modes = yes_only },
    .{ .cfg = shared, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 3, .modes = yes_split },
    .{ .cfg = shared, .k = 2, .maxlit = 1, .conts = P_only, .maxrows = 1, .maxn = 3, .modes = yes_split },
    .{ .cfg = shared_same, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = shared_ml, .k = 2, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 3, .modes = yes_only },
    .{ .cfg = where_other, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_only },
    .{ .cfg = where_both, .k = 2, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 3, .modes = yes_only },
    .{ .cfg = where_one, .k = 2, .maxlit = 2, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = noloop, .k = 2, .maxlit = 3, .conts = FP, .maxrows = 0, .maxn = 4, .modes = all_modes },
    .{ .cfg = ml_ck, .k = 3, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 3, .modes = yes_only },
    .{ .cfg = one, .k = 3, .maxlit = 1, .conts = FP, .maxrows = 1, .maxn = 3, .modes = yes_only },
    .{ .cfg = noloop, .k = 3, .maxlit = 2, .conts = FP, .maxrows = 0, .maxn = 3, .modes = yes_only },
    .{ .cfg = shared, .k = 3, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 2, .modes = yes_only },
    .{ .cfg = shared_ml, .k = 3, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 2, .modes = yes_only },
    .{ .cfg = mlval, .k = 2, .maxlit = 1, .conts = FP, .maxrows = 2, .maxn = 3, .modes = yes_split },
    .{ .cfg = mlval, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = nested, .k = 2, .maxlit = 1, .conts = FP, .maxrows = 2, .maxn = 3, .modes = all_modes },
    .{ .cfg = nested, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_split },
    .{ .cfg = nested_shared, .k = 2, .maxlit = 1, .conts = P_only, .maxrows = 1, .maxn = 3, .modes = yes_split },
    .{ .cfg = nested_shared, .k = 2, .maxlit = 1, .conts = none, .maxrows = 2, .maxn = 4, .modes = yes_only },
    .{ .cfg = mlval, .k = 3, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 3, .modes = yes_only },
    .{ .cfg = nested, .k = 3, .maxlit = 1, .conts = none, .maxrows = 1, .maxn = 3, .modes = yes_only },
};

test "commit realignment: every edit of small layouts routes only what a minimum-operation interpretation allows" {
    // The fixtures' paths are POSIX.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const shard = try shardOf(arena_state.allocator());
    const sweeps: []const Sweep = if (realign_options.full) &full_sweep else &slice_sweep;
    var budget: Budget = .{
        .max_runs = if (realign_options.full) 3_000_000 else 5_000,
        .started = Io.Clock.awake.now(io),
        .max_ms = if (realign_options.full) 8 * 3600 * 1000 else 180_000,
        .io = io,
    };
    var done: std.atomic.Value(bool) = .init(false);
    const watcher = try std.Thread.spawn(.{}, watchdog, .{ io, budget.started, budget.max_ms, &done });
    defer {
        done.store(true, .release);
        watcher.join();
    }
    for (sweeps) |sw| {
        const before = budget.runs;
        const started = Io.Clock.awake.now(io);
        try runSweep(sw, &budget, shard);
        if (realign_options.full) std.debug.print("realign sweep {s} k={d} shard {d}/{d}: {d} commit runs, {d} ms\n", .{ sw.cfg.name, sw.k, shard.i, shard.n, budget.runs - before, started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() });
    }
}
