//! Every axis a source tree references, scanned from `.d/` overlay filenames
//! and directive `when`/`where` expressions.
//!
//! An axis compared against a value (`when os=darwin`, a `.d/profile=work`
//! overlay) classifies a machine, so its value matters: `compared` and
//! `valuesOf` record which axes and which values. An axis only ever tested
//! for presence (`when signing_key`) classifies nothing -- it goes in `names`
//! alone, with no value.

const std = @import("std");
const dsl = @import("../dsl/root.zig");
const source = @import("root.zig");

const Io = std.Io;

const max_bytes: usize = 4 * 1024 * 1024;

/// The multi-value axis names: each binds via a compound `name=value` key
/// rather than a direct one.
pub const multi_value_axis_names = [_][]const u8{ "tool", "env" };

/// Multi-value axes use a compound `name=value` binding key; everything else
/// is a single-value axis addressed by bare name.
pub fn isMultiValueAxis(name: []const u8) bool {
    for (multi_value_axis_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Every reserved axis name: the open multi-value axes (`tool`, `env`) plus
/// `path`, whose closed multi-value axis was deleted (D8) but which stays
/// reserved so a leftover `path=` source errors loudly instead of silently
/// never matching. Reserved against a custom fact or `data/facts.toml` row of
/// the same name, since either would otherwise shadow the axis through the
/// single-value lookup path.
pub const reserved_axis_names = [_][]const u8{ "tool", "env", "path" };

pub fn isReservedAxisName(name: []const u8) bool {
    for (reserved_axis_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// One value a source compares an axis against.
///
/// A Cat B fragment or Cat A/C overlay filename carries two candidate values
/// -- `.d/os/darwin.sh` stands for `os=darwin`, but `.d/hostname/host.local`
/// stands for the whole filename, since a hostname contains dots. Which one it
/// is cannot be settled from the filename alone, so both travel: `value` is
/// the stem and `exact` the verbatim filename. Everything else has a single
/// value and leaves `exact` null.
pub const Value = struct {
    value: []const u8,
    exact: ?[]const u8 = null,
};

/// The set of axis references found in a source tree. `names` holds bare axis
/// names (a single-value binding is published only if its name is here);
/// `values` holds literal `name=value` references for multi-value axes
/// (presence is published only for these exact values); `compared` holds
/// single-value axes the source compares against a value, with `valuesOf`
/// recording which values were seen.
pub const Axes = struct {
    names: std.StringHashMap(void),
    values: std.StringHashMap(void),
    /// Single-value axes the source compares against a value (`when os=darwin`,
    /// a `.d/profile=work` overlay). Only these may have their value published;
    /// an axis merely tested for presence must not.
    compared: std.StringHashMap(void),
    /// Values seen for each `compared` axis.
    valuesOf: std.StringHashMap(std.ArrayList(Value)),
    /// Axes some gate opens on a value no source spells out: a presence
    /// test (`when signing_key`) or a comparison under `not`.
    open: std.StringHashMap(void),

    pub fn referencesName(self: Axes, name: []const u8) bool {
        return self.names.contains(name);
    }
    pub fn referencesValue(self: Axes, compound: []const u8) bool {
        return self.values.contains(compound);
    }
    /// True when the source compares `name` against a value, so simulating this
    /// machine requires knowing which value it holds.
    pub fn comparesValueOf(self: Axes, name: []const u8) bool {
        return self.compared.contains(name);
    }
    pub fn valuesFor(self: Axes, name: []const u8) []const Value {
        const list = self.valuesOf.get(name) orelse return &.{};
        return list.items;
    }
    /// True when some gate on `name` can open for a value no source names.
    pub fn opensOnAnyValue(self: Axes, name: []const u8) bool {
        return self.open.contains(name);
    }
};

fn initAxes(arena: std.mem.Allocator) Axes {
    return .{
        .names = std.StringHashMap(void).init(arena),
        .values = std.StringHashMap(void).init(arena),
        .compared = std.StringHashMap(void).init(arena),
        .valuesOf = std.StringHashMap(std.ArrayList(Value)).init(arena),
        .open = std.StringHashMap(void).init(arena),
    };
}

fn axesArena(ax: *Axes) std.mem.Allocator {
    return ax.names.allocator;
}

fn addName(ax: *Axes, name: []const u8) !void {
    try ax.names.put(name, {});
}

/// Record that `name` was compared against `value` somewhere in the source.
fn addValueOf(ax: *Axes, name: []const u8, value: Value) !void {
    const gop = try ax.valuesOf.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(axesArena(ax), value);
}

/// `exact` is the tuple parsed from a Cat B fragment's or Cat A/C overlay's
/// VERBATIM filename, when its stem-parsed `tuple` dropped a suffix; null for
/// everything else.
fn addTuple(ax: *Axes, tuple: source.tree.AxisTuple, exact: ?source.tree.AxisTuple) !void {
    for (tuple.pairs, 0..) |p, i| {
        try addName(ax, p.name);
        if (isMultiValueAxis(p.name)) {
            try ax.values.put(try std.fmt.allocPrint(axesArena(ax), "{s}={s}", .{ p.name, p.value }), {});
        } else {
            // An overlay named for a value compares against it.
            try ax.compared.put(p.name, {});
            try addValueOf(ax, p.name, .{ .value = p.value, .exact = source.tuple.exactValueAt(exact, i) });
        }
    }
}

/// Position within one file's directive tree. `in_for` mirrors `dsl.driver`'s
/// in-loop parser selection -- true once inside a `for` body, where a
/// standalone `when` carries a row expression instead of an axis one.
/// `loop_vars` holds every enclosing for-loop's variable name, since a bare
/// undotted reference in a row expression names a machine axis only when no
/// loop frame claims it.
const Nest = struct {
    marker: []const u8,
    in_for: bool,
    loop_vars: []const []const u8,
    depth: u32,
};

/// Cap on `scanBody`/`recurseDirective` mutual recursion, mirroring
/// `compose.catB`'s own nesting cap: it bounds a pathological or hostile
/// structure so the scan terminates instead of overflowing the stack.
const max_nest_depth: u32 = 128;

/// Explicit error set for the mutually-recursive `scanBody` <->
/// `recurseDirective` pair: an inferred set cannot resolve across the cycle.
/// Every parse failure on the path between them is caught locally, so
/// `OutOfMemory` is the only error either returns.
const ScanError = std.mem.Allocator.Error;

fn appendStr(arena: std.mem.Allocator, list: []const []const u8, item: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = item;
    return out;
}

/// Parse `content` as one directive-tree scope -- a whole base file, or a
/// nested region body -- record every directive's own axis expressions, then
/// descend into whichever bodies compose itself re-parses.
fn scanBody(ax: *Axes, arena: std.mem.Allocator, content: []const u8, nest: Nest) ScanError!void {
    if (nest.depth > max_nest_depth) return;
    const parsed = if (nest.in_for)
        dsl.driver.parseFileInLoop(arena, content, nest.marker, null) catch return
    else
        dsl.driver.parseFile(arena, content, nest.marker, null) catch return;
    for (parsed.directives) |d| {
        try addDirective(ax, arena, d, nest);
        try recurseDirective(ax, arena, d, nest);
    }
}

/// Descend into the nested bodies compose re-parses for directives: a `when`
/// gate's body and a `for` loop's body template. Every other directive's body
/// -- and every fragment file an `include`/`replace`/`append`/`prepend`/`from`
/// pulls in -- is emitted verbatim, so a `# mox:` line there is content, and
/// reading it as a directive would record an axis nothing ever gates on.
fn recurseDirective(ax: *Axes, arena: std.mem.Allocator, d: dsl.ast.Directive, nest: Nest) ScanError!void {
    switch (d.kind) {
        .when_gate => |k| try scanBody(ax, arena, k.body, .{
            .marker = nest.marker,
            .in_for = nest.in_for,
            .loop_vars = nest.loop_vars,
            .depth = nest.depth + 1,
        }),
        .for_loop => |k| try scanBody(ax, arena, k.body_template, .{
            .marker = nest.marker,
            .in_for = true,
            .loop_vars = try appendStr(arena, nest.loop_vars, k.variable),
            .depth = nest.depth + 1,
        }),
        .include, .replace, .append, .prepend, .remove, .from, .completions, .secret, .default, .keep_empty => {},
    }
}

fn addDirective(ax: *Axes, arena: std.mem.Allocator, d: dsl.ast.Directive, nest: Nest) !void {
    switch (d.kind) {
        .include => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .replace => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .append => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .prepend => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .remove => |k| try addAxisExpr(ax, k.when),
        .when_gate => |k| {
            if (k.when) |w|
                try addAxisExpr(ax, w)
            else if (k.row_when) |r|
                try addRowExpr(ax, r, nest.loop_vars);
        },
        .for_loop => |k| {
            if (k.when) |w| try addAxisExpr(ax, w);
            // `when` runs before any row is bound, so the loop's own variable
            // is not in scope for it; `where` runs per row with that frame
            // already bound, so a bare reference to the variable itself is
            // that row's presence check, not a machine axis.
            if (k.where) |r| try addRowExpr(ax, r, try appendStr(arena, nest.loop_vars, k.variable));
        },
        .completions => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .from, .secret, .default, .keep_empty => {},
    }
}

/// Record `axis` compared against `value`: a multi-value axis publishes only
/// the literal compound, a single-value one becomes a compared axis carrying
/// the value. Under a `not` the gate also opens on values no source names.
fn addComparison(ax: *Axes, axis: []const u8, value: []const u8, negated: bool) !void {
    try addName(ax, axis);
    if (negated) try ax.open.put(axis, {});
    if (isMultiValueAxis(axis)) {
        try ax.values.put(try std.fmt.allocPrint(axesArena(ax), "{s}={s}", .{ axis, value }), {});
    } else {
        try ax.compared.put(axis, {});
        try addValueOf(ax, axis, .{ .value = value });
    }
}

fn addAxisExpr(ax: *Axes, expr: *const dsl.ast.AxisExpr) !void {
    try addAxisExprIn(ax, expr, false);
}

fn addAxisExprIn(ax: *Axes, expr: *const dsl.ast.AxisExpr, negated: bool) !void {
    switch (expr.*) {
        .eq => |e| try addComparison(ax, e.axis, e.value, negated),
        // Presence only: this machine will publish the name, never the value.
        .present => |n| {
            try addName(ax, n);
            try ax.open.put(n, {});
        },
        .not => |inner| try addAxisExprIn(ax, inner, !negated),
        .and_ => |a| {
            try addAxisExprIn(ax, a.left, negated);
            try addAxisExprIn(ax, a.right, negated);
        },
        .or_ => |o| {
            try addAxisExprIn(ax, o.left, negated);
            try addAxisExprIn(ax, o.right, negated);
        },
    }
}

/// True when `ref` names a machine axis rather than a row field: undotted (a
/// dotted head addresses a loop frame) and not itself an enclosing loop
/// variable. `row_expr.evaluate` falls back to a machine-binding lookup for
/// exactly these references.
fn bareAxisRef(ref: []const u8, loop_vars: []const []const u8) bool {
    if (std.mem.indexOfScalar(u8, ref, '.') != null) return false;
    for (loop_vars) |v| {
        if (std.mem.eql(u8, v, ref)) return false;
    }
    return true;
}

fn addRowExpr(ax: *Axes, expr: *const dsl.ast.RowExpr, loop_vars: []const []const u8) !void {
    try addRowExprIn(ax, expr, loop_vars, false);
}

fn addRowExprIn(ax: *Axes, expr: *const dsl.ast.RowExpr, loop_vars: []const []const u8, negated: bool) !void {
    switch (expr.*) {
        // `<axis>=<entry.X>` references the axis by name; the value is a row
        // field known only at compose time, so no literal presence is recorded.
        .axis_with_field => |a| try addName(ax, a.axis),
        // `bound <entry.X>` names no axis statically -- the bound name is
        // itself a row field known only at compose time.
        .bound => {},
        .present => |ref| {
            if (!bareAxisRef(ref, loop_vars)) return;
            try addName(ax, ref);
            try ax.open.put(ref, {});
        },
        .has => |h| {
            if (!bareAxisRef(h.ref, loop_vars)) return;
            try addComparison(ax, h.ref, h.value, negated);
        },
        .eq => |e| {
            if (!bareAxisRef(e.ref, loop_vars)) return;
            try addComparison(ax, e.ref, e.value, negated);
        },
        .not => |inner| try addRowExprIn(ax, inner, loop_vars, !negated),
        .and_ => |a| {
            try addRowExprIn(ax, a.left, loop_vars, negated);
            try addRowExprIn(ax, a.right, loop_vars, negated);
        },
        .or_ => |o| {
            try addRowExprIn(ax, o.left, loop_vars, negated);
            try addRowExprIn(ax, o.right, loop_vars, negated);
        },
    }
}

/// Scan one managed file's overlays, regions, and (if it has a base) directive
/// axis expressions.
fn scanFile(ax: *Axes, arena: std.mem.Allocator, io: Io, file: source.tree.ManagedFile) !void {
    for (file.overlays) |ov| try addTuple(ax, ov.tuple, ov.exact_tuple);
    for (file.regions) |rg| {
        try addName(ax, rg.name);
        for (rg.fragments) |fr| try addTuple(ax, fr.tuple, fr.exact_tuple);
    }
    if (file.has_base and file.source_base_abs.len > 0) {
        const raw = Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_bytes)) catch return;
        const marker = dsl.comment.markerForFile(file.source_base_path, raw) orelse return;
        // A head declaration (`own`/`disown`/`check`) is not DSL syntax --
        // the walk and real compose both strip it before parsing (`compose.
        // catA.readBaseHead`) -- so it must be stripped here too, or a file
        // that leads with one fails to parse at the very first line and this
        // scan silently sees none of its directives, including its own
        // whole-file gate.
        const head_text = raw[0..@min(raw.len, source.tree.max_head_bytes)];
        const head_parsed = source.head.parse(arena, head_text, marker) catch |e| switch (e) {
            error.OutOfMemory => return e,
            // A malformed head is the walk's problem to report; scan the
            // unstripped text rather than giving up on this file entirely.
            else => source.head.Parsed{},
        };
        const content = if (head_parsed.spans.len == 0) raw else try source.head.stripSpans(arena, raw, head_parsed.spans);
        try scanBody(ax, arena, content, .{ .marker = marker, .in_for = false, .loop_vars = &.{}, .depth = 0 });
    }
}

/// Scan `<repo>/src` for every axis referenced anywhere: `.d/` tuple filenames
/// and every directive `when`/`where` axis expression.
pub fn ofTree(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !Axes {
    const src_dir = try std.fs.path.join(arena, &.{ repo_dir, "src" });
    const tree = source.tree.walk(arena, io, src_dir, "") catch |e| switch (e) {
        error.FileNotFound => return initAxes(arena),
        else => return e,
    };
    return ofManagedTree(arena, io, tree);
}

/// Same scan as `ofTree`, over a tree the caller already walked -- so a
/// caller that walked once (and handled a walk error with its own
/// diagnostics) scans that same result instead of re-walking and re-raising
/// a raw, undiagnosed error on the same problem.
pub fn ofManagedTree(arena: std.mem.Allocator, io: Io, tree: source.tree.ManagedTree) !Axes {
    var ax = initAxes(arena);
    for (tree.files) |file| try scanFile(&ax, arena, io, file);
    return ax;
}

/// Scan a single managed file for the axes it references.
pub fn ofFile(arena: std.mem.Allocator, io: Io, file: source.tree.ManagedFile) !Axes {
    var ax = initAxes(arena);
    try scanFile(&ax, arena, io, file);
    return ax;
}

/// Every axis `expr` references, without scanning a whole source tree --
/// e.g. a single file's whole-file gate, handed back for inspection after a
/// skip.
pub fn ofAxisExpr(arena: std.mem.Allocator, expr: *const dsl.ast.AxisExpr) !Axes {
    var ax = initAxes(arena);
    try addAxisExpr(&ax, expr);
    return ax;
}

/// `file`'s own compared axis NAMES, each carrying the REPO-WIDE value SET
/// seen anywhere under `repo_dir` (`ofTree`) rather than just what `file`
/// itself names. A machine revealed only by another file's overlay (an
/// `os=linux` a sibling declares) enters the space this way, while an axis no
/// file references stays out -- no phantom dimension. Used to enumerate the
/// blast radius of a structured (Cat-A merged) file's key-path edit, which
/// must be sound over the whole repo, not just this file's own directives.
pub fn ofFileOverTree(arena: std.mem.Allocator, io: Io, file: source.tree.ManagedFile, repo_dir: []const u8) !Axes {
    const file_ax = try ofFile(arena, io, file);
    const tree_ax = try ofTree(arena, io, repo_dir);

    var ax = initAxes(arena);
    var it = file_ax.compared.keyIterator();
    while (it.next()) |name| {
        try ax.compared.put(name.*, {});
        try ax.names.put(name.*, {});
        if (tree_ax.valuesOf.get(name.*)) |list| try ax.valuesOf.put(name.*, list);
    }
    return ax;
}

test "ofFile: a value comparison makes an axis; a presence test does not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when os=darwin\n" ++
        "\tprogram = /darwin\n" ++
        "# mox: end\n" ++
        "# mox: when signing_key\n" ++
        "\tgpgsign = true\n" ++
        "# mox: end\n");

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try ofFile(a, io, tree.files[0]);

    // os is compared against a value: it classifies, and its values are known.
    try std.testing.expect(ax.comparesValueOf("os"));
    try std.testing.expectEqualStrings("darwin", ax.valuesFor("os")[0].value);

    // signing_key is only ever asked "do you exist?": it is not an axis.
    try std.testing.expect(ax.referencesName("signing_key"));
    try std.testing.expect(!ax.comparesValueOf("signing_key"));
    try std.testing.expectEqual(@as(usize, 0), ax.valuesFor("signing_key").len);
}

test "ofFile: a .d overlay filename is a value comparison" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/profile=work", "[user]\n  name = w\n");

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try ofFile(a, io, tree.files[0]);

    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expectEqualStrings("work", ax.valuesFor("profile")[0].value);
}

test "ofFile: a .psm1 gated on os=windows is a value comparison" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/AesEncrypt.psm1", "# mox: when os=windows\n" ++
        "function Protect-String { }\n");

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try ofFile(a, io, tree.files[0]);

    try std.testing.expect(ax.comparesValueOf("os"));
    try std.testing.expectEqualStrings("windows", ax.valuesFor("os")[0].value);
}

test "ofFile: a whole-file gate behind head ownership declarations is still recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A leading `own`/`check` block is not DSL syntax; real compose strips
    // it before parsing (`compose.catA.readBaseHead`), and this scan must
    // do the same or it fails on the very first line and never reaches the
    // `when tool=codex` gate that follows.
    try writeFile(io, tmp.dir, "src/.codex/config.toml", "# mox: own tui.keymap.global\n" ++
        "# mox: check \"scripts/check/codex-config\"\n" ++
        "# mox: when tool=codex\n" ++
        "[tui.keymap.global]\n" ++
        "x = 1\n");

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try ofFile(a, io, tree.files[0]);

    try std.testing.expect(ax.referencesName("tool"));
    try std.testing.expect(ax.referencesValue("tool=codex"));
}

test "ofTree: tuple names and directive axes; interpolation-only fact absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A Cat A overlay names the `os` axis; a base gates on `profile=work` and
    // interpolates `<machine.email>` (email is NOT an axis).
    try tmp.dir.createDirPath(io, "repo/src/.gitconfig.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig", .data = "[user]\n# mox: when profile=work\n  name = Work\n# mox: end\n  email = <machine.email>\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig.d/os=darwin", .data = "y\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    const ax = try ofTree(a, io, repo);
    try std.testing.expect(ax.referencesName("os"));
    try std.testing.expect(ax.referencesName("profile"));
    // Interpolation-only fact is never an axis.
    try std.testing.expect(!ax.referencesName("email"));
}

test "ofTree: multi-value axis records the literal value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "# mox: when tool=starship\neval starship\n# mox: end\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    const ax = try ofTree(a, io, repo);
    try std.testing.expect(ax.referencesName("tool"));
    try std.testing.expect(ax.referencesValue("tool=starship"));
    try std.testing.expect(!ax.referencesValue("tool=fd"));
}

/// Walk `src/<name>` written with `content` and return the axes scanned from it.
fn axesOfSingleFile(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, content: []const u8) !Axes {
    const io = std.testing.io;
    try writeFile(io, tmp.dir, try std.fs.path.join(a, &.{ "src", name }), content);
    const src_dir = try srcPathAlloc(a, tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    return ofFile(a, io, tree.files[0]);
}

test "ofFile: a gate nested inside another gate has its own axis compared and referenced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: when os=darwin\n" ++
        "# mox: when profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.comparesValueOf("os"));
    try std.testing.expect(ax.referencesName("profile"));
    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expectEqualStrings("work", ax.valuesFor("profile")[0].value);
}

test "ofFile: a gate three levels deep has its own axis compared and referenced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: when os=darwin\n" ++
        "# mox: when profile=work\n" ++
        "# mox: when hostname=host.local\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.comparesValueOf("hostname"));
    try std.testing.expect(ax.referencesName("hostname"));
    try std.testing.expectEqualStrings("host.local", ax.valuesFor("hostname")[0].value);
}

test "ofFile: a gate nested in a for-loop body has its bare machine axis compared and referenced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Inside a loop body a standalone `when` parses with the ROW grammar, where
    // an undotted reference is a machine-axis test and a dotted one is a row
    // field.
    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: for id in \"data/ids.toml\"\n" ++
        "# mox: when profile=work and id.signing_key\n" ++
        "\tsigningkey = <id.signing_key>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.referencesName("profile"));
    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expectEqualStrings("work", ax.valuesFor("profile")[0].value);
    // The dotted row-field reference names no axis.
    try std.testing.expect(!ax.referencesName("id"));
    try std.testing.expect(!ax.referencesName("signing_key"));
}

test "ofFile: a for-loop body's in-loop gate on the loop variable itself records no axis" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: for id in \"data/ids.toml\"\n" ++
        "# mox: when id and profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    // The sibling comparison proves the body was reached and parsed, so the
    // loop variable's absence is a decision rather than a failed parse.
    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expect(!ax.referencesName("id"));
}

test "ofFile: a for-loop `where` on the loop's own variable records no axis" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: for id in \"data/ids.toml\" where id and profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expect(!ax.referencesName("id"));
}

test "ofFile: a for-loop nested inside a gate has its body's axis compared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: when os=darwin\n" ++
        "# mox: for id in \"data/ids.toml\"\n" ++
        "# mox: when profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.comparesValueOf("os"));
    try std.testing.expect(ax.comparesValueOf("profile"));
}

test "ofFile: a nested gate on a multi-value axis records the literal value, not a comparison" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".zshrc", "# mox: when os=darwin\n" ++
        "# mox: when tool=starship\n" ++
        "eval starship\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.referencesValue("tool=starship"));
    try std.testing.expect(!ax.comparesValueOf("tool"));
}

test "ofFile: a nested presence test records the name and opens the axis on any value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: when os=darwin\n" ++
        "# mox: when signing_key\n" ++
        "\tgpgsign = true\n" ++
        "# mox: end\n" ++
        "# mox: when not profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n");

    try std.testing.expect(ax.referencesName("signing_key"));
    try std.testing.expect(!ax.comparesValueOf("signing_key"));
    try std.testing.expect(ax.opensOnAnyValue("signing_key"));
    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expect(ax.opensOnAnyValue("profile"));
}

test "ofFile: a `# mox: when` line inside a replace body records no axis" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Compose emits a `replace` fallback body verbatim and never re-parses it,
    // so a directive-looking line there is content -- recording its axis would
    // invent a dimension nothing gates on.
    const ax = try axesOfSingleFile(a, &tmp, ".gitconfig", "# mox: replace \"frag\" when os=darwin\n" ++
        "# mox: when profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n" ++
        "# mox: when hostname=host.local\n" ++
        "\ty = 1\n" ++
        "# mox: end\n");

    // The trailing real gate proves the file parsed to completion, so
    // `profile`'s absence is a decision rather than a failed parse.
    try std.testing.expect(ax.comparesValueOf("os"));
    try std.testing.expect(ax.comparesValueOf("hostname"));
    try std.testing.expect(!ax.referencesName("profile"));
}

test "ofTree: a nested gate's axis value reaches the repo-wide value set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig", .data = "# mox: when os=darwin\n" ++
        "# mox: when os=macos\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    const ax = try ofTree(a, io, repo);
    var saw_macos = false;
    for (ax.valuesFor("os")) |v| {
        if (std.mem.eql(u8, v.value, "macos")) saw_macos = true;
    }
    try std.testing.expect(saw_macos);
}

test "ofFileOverTree: an axis compared only by a nested gate carries the repo-wide value set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `.gitconfig` compares `profile` only inside its `os=darwin` gate; a
    // sibling file names the `profile=personal` value. A structured promote
    // must enumerate both values, so the nested comparison has to reach here.
    try tmp.dir.createDirPath(io, "repo/src/.zshrc.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig", .data = "# mox: when os=darwin\n" ++
        "# mox: when profile=work\n" ++
        "\tx = 1\n" ++
        "# mox: end\n" ++
        "# mox: end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "common\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc.d/profile=personal", .data = "personal\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const src_dir = try std.fs.path.join(a, &.{ repo, "src" });
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");

    const gitconfig = for (tree.files) |f| {
        if (std.mem.endsWith(u8, f.source_base_path, ".gitconfig")) break f;
    } else return error.FixtureMissing;

    const ax = try ofFileOverTree(a, io, gitconfig, repo);
    try std.testing.expect(ax.comparesValueOf("profile"));
    var saw_work = false;
    var saw_personal = false;
    for (ax.valuesFor("profile")) |v| {
        if (std.mem.eql(u8, v.value, "work")) saw_work = true;
        if (std.mem.eql(u8, v.value, "personal")) saw_personal = true;
    }
    try std.testing.expect(saw_work);
    try std.testing.expect(saw_personal);
}

test "ofFile: a markerless-extension base with an apparent `# mox:` directive resolves via the shebang/apparent-directive fallback" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No dot anywhere in the basename, so `markerForExtension` has no entry
    // and there is no shebang either -- only the apparent `# mox:` line
    // signals the marker.
    try writeFile(io, tmp.dir, "src/allowed_signers", "user namespaces=\"git\"\n# mox: when profile=work\nx = 1\n# mox: end\n");

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try ofFile(a, io, tree.files[0]);

    try std.testing.expect(ax.comparesValueOf("profile"));
    try std.testing.expectEqualStrings("work", ax.valuesFor("profile")[0].value);
}

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

/// Build the absolute path to `<tmp>/src` using `tmp.parent_dir` to compute the
/// canonical `<cwd>/.zig-cache/tmp/<sub_path>` location.
fn srcPathAlloc(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "src" });
}
