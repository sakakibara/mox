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
};

fn initAxes(arena: std.mem.Allocator) Axes {
    return .{
        .names = std.StringHashMap(void).init(arena),
        .values = std.StringHashMap(void).init(arena),
        .compared = std.StringHashMap(void).init(arena),
        .valuesOf = std.StringHashMap(std.ArrayList(Value)).init(arena),
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
            const exact_value: ?[]const u8 = if (exact) |t|
                (if (i < t.pairs.len) t.pairs[i].value else null)
            else
                null;
            try addValueOf(ax, p.name, .{ .value = p.value, .exact = exact_value });
        }
    }
}

fn addDirective(ax: *Axes, d: dsl.ast.Directive) !void {
    switch (d.kind) {
        .include => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .replace => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .append => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .prepend => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .remove => |k| try addAxisExpr(ax, k.when),
        .when_gate => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .for_loop => |k| {
            if (k.when) |w| try addAxisExpr(ax, w);
            if (k.where) |r| try addRowExpr(ax, r);
        },
        .completions => |k| if (k.when) |w| try addAxisExpr(ax, w),
        .from, .secret => {},
    }
}

fn addAxisExpr(ax: *Axes, expr: *const dsl.ast.AxisExpr) !void {
    switch (expr.*) {
        .eq => |e| {
            try addName(ax, e.axis);
            if (isMultiValueAxis(e.axis)) {
                try ax.values.put(try std.fmt.allocPrint(axesArena(ax), "{s}={s}", .{ e.axis, e.value }), {});
            } else {
                try ax.compared.put(e.axis, {});
                try addValueOf(ax, e.axis, .{ .value = e.value });
            }
        },
        // Presence only: this machine will publish the name, never the value.
        .present => |n| try addName(ax, n),
        .not => |inner| try addAxisExpr(ax, inner),
        .and_ => |a| {
            try addAxisExpr(ax, a.left);
            try addAxisExpr(ax, a.right);
        },
        .or_ => |o| {
            try addAxisExpr(ax, o.left);
            try addAxisExpr(ax, o.right);
        },
    }
}

fn addRowExpr(ax: *Axes, expr: *const dsl.ast.RowExpr) !void {
    switch (expr.*) {
        // `<axis>=<entry.X>` references the axis by name; the value is a row
        // field known only at compose time, so no literal presence is recorded.
        .axis_with_field => |a| try addName(ax, a.axis),
        // `bound <entry.X>` names no axis statically either -- the bound
        // name is itself a row field known only at compose time.
        .present, .has, .eq, .bound => {},
        .not => |inner| try addRowExpr(ax, inner),
        .and_ => |a| {
            try addRowExpr(ax, a.left);
            try addRowExpr(ax, a.right);
        },
        .or_ => |o| {
            try addRowExpr(ax, o.left);
            try addRowExpr(ax, o.right);
        },
    }
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
        const marker = dsl.comment.markerForExtension(identForMarker(file.source_base_path)) orelse return;
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
        const parsed = dsl.driver.parseFile(arena, content, marker, null) catch return;
        for (parsed.directives) |d| try addDirective(ax, d);
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
