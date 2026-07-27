//! Config-space discovery: a dedicated pre-interview pass that scans a repo's
//! `src/` tree and `scripts/pre|post` trees for every custom fact ("dimension")
//! the repo's sources actually consume, instead of a hand-maintained schema
//! file. Pure function of (repo_dir, io, alloc): no state is written, and the
//! result is not yet wired into `apply` or any command.
//!
//! A dimension is discovered through three channels:
//!   - value-compared: `name=value` in a gate, region, whole-file gate, overlay
//!     filename tuple, generator gate, or script `# mox: when` head, with the
//!     observed literal value set (a `name = <var>.field` row predicate is
//!     value-compared with an EMPTY observed set; `bound <var>.field` names no
//!     axis and contributes nothing).
//!   - captured: `<machine.NAME>` occurrences in a managed file's base content,
//!     each with its `| default` and the innermost enclosing `# mox: when`
//!     region(s) (recursively) combined with the whole-file gate, if any.
//!   - presence-only: a bare `when NAME` gate.
//!
//! Built-ins, the open probe axes, reserved axis names, and `data/facts.toml`-
//! derived names are excluded by category, never by a hand-written name list.

const std = @import("std");
const dsl = @import("../dsl/root.zig");
const source = @import("../source/root.zig");
const state = @import("state.zig");
const derived_facts = @import("derived_facts.zig");

const Io = std.Io;
const AxisExpr = dsl.ast.AxisExpr;

const max_file_bytes: usize = 4 * 1024 * 1024;
const max_script_bytes: usize = 4 * 1024 * 1024;

/// Which ways a dimension's name is referenced. Not mutually exclusive: a
/// name gated with `when profile=work` elsewhere AND captured as
/// `<machine.profile>` carries both `value_compared` and `captured`.
pub const Roles = struct {
    value_compared: bool = false,
    captured: bool = false,
    presence: bool = false,
};

pub const Provenance = struct {
    /// Number of distinct source files (`src/` tree files and scripts) that
    /// reference this dimension via a value-compared, presence, or capture
    /// occurrence. A script's `# mox: needs`/`MOX_FACT_*` consumption is
    /// tracked separately in `needing_scripts`, not counted here.
    source_count: usize,
    /// Repo-relative paths of scripts that consume this dimension: via
    /// `# mox: needs` when present, else via a `MOX_FACT_<NAME>` token found
    /// in the script's text. Sorted, deduped.
    needing_scripts: []const []const u8,
};

pub const Dimension = struct {
    name: []const u8,
    roles: Roles,
    /// Observed literal values (gate/region/overlay/generator/script-when
    /// comparisons), sorted and deduped. Empty for a name only ever compared
    /// via a `name = <var>.field` row predicate, or only ever captured.
    observed_values: []const []const u8,
    /// Every distinct `| default "..."` value observed on a capture of this
    /// name, sorted and deduped.
    capture_defaults: []const []const u8,
    /// The OR of the enclosing-gate expressions of this dimension's CAPTURE
    /// occurrences. Null when the dimension has any value-compared or
    /// presence occurrence (the comparison itself is the demand -- D2), or
    /// when any capture occurrence is unconditioned, or when it has no
    /// capture occurrence at all.
    asking_condition: ?*const AxisExpr,
    provenance: Provenance,
};

pub const ScriptRecord = struct {
    /// Repo-relative path, e.g. `scripts/pre/00-brew.sh`.
    path: []const u8,
    /// Raw expression text of a `# mox: when <expr>` head line, or null.
    when_head: ?[]const u8,
    /// Literal `MOX_FACT_[A-Z0-9_]+` tokens found anywhere in the script's
    /// text, sorted and deduped.
    scanned_tokens: []const []const u8,
    /// Parsed `# mox: needs <name>...` head line: null when the script has no
    /// such directive; an empty (non-null) slice when it declares no facts
    /// needed. When non-null, REPLACES `scanned_tokens` as this script's
    /// effective consumption set.
    needs: ?[]const []const u8,
};

pub const Discovery = struct {
    /// Every discovered dimension, sorted by name.
    dimensions: []const Dimension,
    /// Every scanned script, in scan order (scripts/pre then scripts/post,
    /// each subtree in sorted directory order).
    scripts: []const ScriptRecord,
};

/// A `# mox: needs <name>...` name fails the fact-name charset
/// (`[a-z][a-z0-9_]*`, matching `data/facts.toml` and `facts.toml`).
pub const DiscoverError = error{InvalidNeedsName};

/// Discover the full config space a repo's sources consume. `repo_dir` is the
/// mox repo root (the parent of `src/`); a missing `src/`, `scripts/pre/`, or
/// `scripts/post/` is not an error. Does not read or depend on the private
/// layer or any machine-local state: same result on every machine for the
/// same repo tree.
pub fn discover(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !Discovery {
    var self: Discoverer = .{
        .arena = arena,
        .io = io,
        .dims = std.StringHashMap(DimWork).init(arena),
        .derived_names = std.StringHashMap(void).init(arena),
        .scripts = .empty,
    };

    for (try derived_facts.declaredNames(arena, io, repo_dir, "")) |n| {
        try self.derived_names.put(n, {});
    }

    const src_dir = try std.fs.path.join(arena, &.{ repo_dir, "src" });
    const tree = source.tree.walk(arena, io, src_dir, "") catch |e| switch (e) {
        error.FileNotFound => source.tree.ManagedTree{ .files = &.{} },
        else => return e,
    };
    for (tree.files) |file| try self.scanManagedFile(file);

    inline for (.{ "pre", "post" }) |stage| {
        const abs = try std.fs.path.join(arena, &.{ repo_dir, "scripts", stage });
        try self.scanScriptsTree(abs, "scripts/" ++ stage);
    }

    return self.finalize();
}

/// Per-dimension scan state, held in `Discoverer.dims` keyed by name.
const DimWork = struct {
    roles: Roles = .{},
    observed_values: std.StringHashMap(void),
    capture_defaults: std.StringHashMap(void),
    /// One entry per capture occurrence: its enclosing-gate condition, or
    /// null when unconditioned. Order does not matter (OR is commutative).
    capture_conditions: std.ArrayList(?*const AxisExpr),
    sources: std.StringHashMap(void),
};

const Discoverer = struct {
    arena: std.mem.Allocator,
    io: Io,
    dims: std.StringHashMap(DimWork),
    derived_names: std.StringHashMap(void),
    scripts: std.ArrayList(ScriptRecord),

    /// The dimension work-slot for `name`, creating it on first reference, or
    /// null when `name` is excluded by category (built-in, open axis,
    /// reserved, or `data/facts.toml`-derived). Excluded names never enter
    /// `dims` at all.
    fn dimFor(self: *Discoverer, name: []const u8) !?*DimWork {
        if (isExcluded(self, name)) return null;
        const gop = try self.dims.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.arena.dupe(u8, name);
            gop.value_ptr.* = .{
                .observed_values = std.StringHashMap(void).init(self.arena),
                .capture_defaults = std.StringHashMap(void).init(self.arena),
                .capture_conditions = .empty,
                .sources = std.StringHashMap(void).init(self.arena),
            };
        }
        return gop.value_ptr;
    }

    fn isExcluded(self: *Discoverer, name: []const u8) bool {
        return state.isBuiltinField(name) or
            source.axes.isReservedAxisName(name) or
            self.derived_names.contains(name);
    }

    // -- axis (value-compared / presence) scanning --------------------------

    fn recordAxisExpr(self: *Discoverer, expr: *const AxisExpr, source_key: []const u8) !void {
        switch (expr.*) {
            .eq => |e| {
                if (try self.dimFor(e.axis)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.observed_values.put(try self.arena.dupe(u8, e.value), {});
                    try dw.sources.put(source_key, {});
                }
            },
            .present => |n| {
                if (try self.dimFor(n)) |dw| {
                    dw.roles.presence = true;
                    try dw.sources.put(source_key, {});
                }
            },
            .not => |inner| try self.recordAxisExpr(inner, source_key),
            .and_ => |a| {
                try self.recordAxisExpr(a.left, source_key);
                try self.recordAxisExpr(a.right, source_key);
            },
            .or_ => |o| {
                try self.recordAxisExpr(o.left, source_key);
                try self.recordAxisExpr(o.right, source_key);
            },
        }
    }

    fn recordRowExpr(self: *Discoverer, expr: *const dsl.ast.RowExpr, source_key: []const u8) !void {
        switch (expr.*) {
            // `<axis>=<var>.field`: the axis name is static even though the
            // compared value is a row field known only at compose time, so it
            // is value-compared with an empty observed set.
            .axis_with_field => |a| {
                if (try self.dimFor(a.axis)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.sources.put(source_key, {});
                }
            },
            // `bound <var>.field` names no axis statically (the bound name is
            // itself a row field); `present`/`has`/`eq` reference row fields,
            // not machine axes. None of these are a discovery source.
            .present, .has, .eq, .bound => {},
            .not => |inner| try self.recordRowExpr(inner, source_key),
            .and_ => |a| {
                try self.recordRowExpr(a.left, source_key);
                try self.recordRowExpr(a.right, source_key);
            },
            .or_ => |o| {
                try self.recordRowExpr(o.left, source_key);
                try self.recordRowExpr(o.right, source_key);
            },
        }
    }

    /// A top-level directive's own axis/row expressions, mirroring
    /// `source.axes`'s directive scan exactly (same depth: a nested directive
    /// inside a region's body is not visited here for axis purposes).
    fn recordDirectiveAxes(self: *Discoverer, d: dsl.ast.Directive, source_key: []const u8) !void {
        switch (d.kind) {
            .include => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .replace => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .append => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .prepend => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .remove => |k| try self.recordAxisExpr(k.when, source_key),
            .when_gate => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .for_loop => |k| {
                if (k.when) |w| try self.recordAxisExpr(w, source_key);
                if (k.where) |r| try self.recordRowExpr(r, source_key);
            },
            .completions => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key),
            .from, .secret => {},
        }
    }

    fn recordTuple(self: *Discoverer, tuple: source.tree.AxisTuple, source_key: []const u8) !void {
        for (tuple.pairs) |p| {
            if (try self.dimFor(p.name)) |dw| {
                dw.roles.value_compared = true;
                try dw.observed_values.put(try self.arena.dupe(u8, p.value), {});
                try dw.sources.put(source_key, {});
            }
        }
    }

    // -- capture scanning -----------------------------------------------

    /// Scan `content` (and, recursively, every nested `# mox: when` region's
    /// body) for `<machine.NAME>` occurrences. `gate_stack` holds every
    /// enclosing gate's condition on the path from the file root to this
    /// scope, innermost last; a capture's condition is their conjunction.
    ///
    /// Only `when_gate` bodies are recursed into: a capture inside a
    /// `replace`/`append`/`prepend`/`for` region is not scanned in this fold
    /// (no fixture requires it, and their body's emission semantics are not
    /// simply "always present under this gate").
    fn scanCaptureScope(
        self: *Discoverer,
        content: []const u8,
        marker: []const u8,
        gate_stack: []const *const AxisExpr,
        source_key: []const u8,
    ) !void {
        const parsed = dsl.driver.parseFile(self.arena, content, marker, null) catch return;
        const condition = try combineAnd(self.arena, gate_stack);

        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (lineCovered(parsed.directives, line_no)) continue;
            try self.scanCapturesInLine(line, condition, source_key);
        }

        for (parsed.directives) |d| {
            if (d.kind != .when_gate) continue;
            const w = d.kind.when_gate;
            // `row_when` (in-loop grammar) never appears here: this scan
            // never recurses with the loop parser, so every when_gate reached
            // here was parsed outside a loop and carries `when`.
            const expr = w.when orelse continue;
            var new_stack = try self.arena.alloc(*const AxisExpr, gate_stack.len + 1);
            @memcpy(new_stack[0..gate_stack.len], gate_stack);
            new_stack[gate_stack.len] = expr;
            try self.scanCaptureScope(w.body, marker, new_stack, source_key);
        }
    }

    fn scanCapturesInLine(self: *Discoverer, line: []const u8, condition: ?*const AxisExpr, source_key: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, "<machine.")) |open| {
            const close = captureClose(line, open) orelse {
                i = open + 1;
                continue;
            };
            const inner = line[open + 1 .. close];
            i = close + 1;

            const split = splitDefault(inner);
            const field = split.field["machine.".len..];
            if (field.len == 0) continue;
            // Open axis: excluded by category, not by name list, but skipped
            // here up front since `tool_path.<name>` is not itself a single
            // dimension name `dimFor` would even parse sensibly.
            if (std.mem.startsWith(u8, field, "tool_path.")) continue;

            const dw = (try self.dimFor(field)) orelse continue;
            dw.roles.captured = true;
            try dw.sources.put(source_key, {});
            try dw.capture_conditions.append(self.arena, condition);
            if (split.default) |def| try dw.capture_defaults.put(try self.arena.dupe(u8, def), {});
        }
    }

    // -- per-file dispatch ------------------------------------------------

    fn scanManagedFile(self: *Discoverer, file: source.tree.ManagedFile) !void {
        const source_key = file.source_base_path;

        for (file.overlays) |ov| try self.recordTuple(ov.tuple, source_key);
        for (file.regions) |rg| {
            // A Cat B region's mere existence means its name is compared
            // against whatever fragment stems it has, even should that ever
            // be zero (an empty region directory).
            if (try self.dimFor(rg.name)) |dw| {
                dw.roles.value_compared = true;
                try dw.sources.put(source_key, {});
            }
            for (rg.fragments) |fr| try self.recordTuple(fr.tuple, source_key);
        }

        if (!file.has_base or file.source_base_abs.len == 0) return;

        const raw = Io.Dir.cwd().readFileAlloc(self.io, file.source_base_abs, self.arena, .limited(max_file_bytes)) catch return;
        const marker = dsl.comment.markerForExtension(identForMarker(file.source_base_path)) orelse return;
        const head_text = raw[0..@min(raw.len, source.tree.max_head_bytes)];
        const head_parsed = source.head.parse(self.arena, head_text, marker) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => source.head.Parsed{},
        };
        const content = if (head_parsed.spans.len == 0) raw else try source.head.stripSpans(self.arena, raw, head_parsed.spans);

        const parsed = dsl.driver.parseFile(self.arena, content, marker, null) catch return;
        for (parsed.directives) |d| try self.recordDirectiveAxes(d, source_key);

        try self.scanCaptureScope(content, marker, &.{}, source_key);
    }

    // -- scripts tree -------------------------------------------------------

    fn scanScriptsTree(self: *Discoverer, abs_dir: []const u8, rel_prefix: []const u8) !void {
        const entries = try source.dirent.sortedPath(self.arena, self.io, abs_dir, .{ .iterate = true });
        for (entries) |e| {
            const abs = try std.fs.path.join(self.arena, &.{ abs_dir, e.name });
            const rel = try source.path.joinKey(self.arena, &.{ rel_prefix, e.name });
            switch (e.kind) {
                .directory => try self.scanScriptsTree(abs, rel),
                .file => try self.scanScriptFile(abs, rel),
                else => {},
            }
        }
    }

    fn scanScriptFile(self: *Discoverer, abs_path: []const u8, rel_path: []const u8) !void {
        const content = Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.arena, .limited(max_script_bytes)) catch return;

        const head = scanScriptHead(content);
        if (head.when) |expr_src| {
            if (dsl.axis.parseString(self.arena, expr_src)) |expr| {
                try self.recordAxisExpr(expr, rel_path);
            } else |_| {
                // A malformed head expression is the apply-time run's problem
                // to report; discovery keeps the raw text and contributes no
                // axis role from it.
            }
        }

        var needs: ?[]const []const u8 = null;
        if (head.needs) |raw| needs = try parseNeeds(self.arena, raw);

        try self.scripts.append(self.arena, .{
            .path = rel_path,
            .when_head = head.when,
            .scanned_tokens = try scanMoxFactTokens(self.arena, content),
            .needs = needs,
        });
    }

    // -- final assembly -----------------------------------------------------

    fn finalize(self: *Discoverer) !Discovery {
        var dims_out: std.ArrayList(Dimension) = .empty;
        var it = self.dims.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const dw = entry.value_ptr;
            try dims_out.append(self.arena, .{
                .name = name,
                .roles = dw.roles,
                .observed_values = try sortedKeys(self.arena, &dw.observed_values),
                .capture_defaults = try sortedKeys(self.arena, &dw.capture_defaults),
                .asking_condition = try computeAskingCondition(self.arena, dw),
                .provenance = .{
                    .source_count = dw.sources.count(),
                    .needing_scripts = try self.needingScripts(name),
                },
            });
        }
        const dims_slice = try dims_out.toOwnedSlice(self.arena);
        std.mem.sort(Dimension, dims_slice, {}, struct {
            fn lessThan(_: void, a: Dimension, b: Dimension) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        return .{ .dimensions = dims_slice, .scripts = try self.scripts.toOwnedSlice(self.arena) };
    }

    /// Every script that effectively consumes `dim_name`: via `# mox: needs`
    /// when the script declares one (direct name match), else via a
    /// `MOX_FACT_<NAME>` token found in its text (matched against the same
    /// sanitize rule `apply.run_scripts.buildScriptEnv` projects facts
    /// through). Sorted, deduped by construction (one entry per script).
    fn needingScripts(self: *Discoverer, dim_name: []const u8) ![]const []const u8 {
        const token = try factEnvName(self.arena, dim_name);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.scripts.items) |s| {
            const consumes = if (s.needs) |names| blk: {
                for (names) |n| {
                    if (std.mem.eql(u8, n, dim_name)) break :blk true;
                }
                break :blk false;
            } else blk: {
                for (s.scanned_tokens) |t| {
                    if (std.mem.eql(u8, t, token)) break :blk true;
                }
                break :blk false;
            };
            if (consumes) try out.append(self.arena, s.path);
        }
        const slice = try out.toOwnedSlice(self.arena);
        std.mem.sort([]const u8, slice, {}, lessThanStr);
        return slice;
    }
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// True when `line_no` (1-indexed) falls within some top-level directive's
/// span -- its marker line(s) and, for a region, its body -- so it is not
/// "content outside all directives".
fn lineCovered(directives: []const dsl.ast.Directive, line_no: u32) bool {
    for (directives) |d| {
        if (line_no >= d.start_line and line_no <= d.end_line) return true;
    }
    return false;
}

fn combineAnd(arena: std.mem.Allocator, exprs: []const *const AxisExpr) !?*const AxisExpr {
    if (exprs.len == 0) return null;
    var acc = exprs[0];
    for (exprs[1..]) |e| {
        const node = try arena.create(AxisExpr);
        node.* = .{ .and_ = .{ .left = acc, .right = e } };
        acc = node;
    }
    return acc;
}

fn combineOr(arena: std.mem.Allocator, a: ?*const AxisExpr, b: *const AxisExpr) !*const AxisExpr {
    const left = a orelse return b;
    const node = try arena.create(AxisExpr);
    node.* = .{ .or_ = .{ .left = left, .right = b } };
    return node;
}

/// Null when the dimension has any value-compared or presence occurrence
/// (per D2, that comparison IS the demand, unconditionally), when it has no
/// capture occurrence at all, or when any capture occurrence is itself
/// unconditioned. Otherwise the OR of every capture occurrence's condition.
fn computeAskingCondition(arena: std.mem.Allocator, dw: *const DimWork) !?*const AxisExpr {
    if (dw.roles.value_compared or dw.roles.presence) return null;
    if (dw.capture_conditions.items.len == 0) return null;
    var combined: ?*const AxisExpr = null;
    for (dw.capture_conditions.items) |maybe_cond| {
        const cond = maybe_cond orelse return null;
        combined = try combineOr(arena, combined, cond);
    }
    return combined;
}

/// Index of the `>` that closes a `<machine....>` capture opened at `open`
/// (the index of `<`). Mirrors `compose.interp`'s default-aware close scan (a
/// `| default "...>..."` value may itself embed `>`), minus the `<secret:>`
/// special case that never applies to a `machine.` capture.
fn captureClose(line: []const u8, open: usize) ?usize {
    const naive = std.mem.indexOfScalarPos(u8, line, open + 1, '>') orelse return null;
    const marker = " | default \"";
    const mpos = std.mem.indexOfPos(u8, line[0..naive], open + 1, marker) orelse return naive;
    const qstart = mpos + marker.len;
    var k = qstart;
    while (k + 1 < line.len) : (k += 1) {
        if (line[k] == '"' and line[k + 1] == '>') return k + 1;
    }
    return naive;
}

/// Split a capture body (`machine.NAME` or `machine.NAME | default "..."`)
/// into its field reference and optional default value.
fn splitDefault(inner: []const u8) struct { field: []const u8, default: ?[]const u8 } {
    const marker = " | default \"";
    const idx = std.mem.indexOf(u8, inner, marker) orelse return .{ .field = inner, .default = null };
    const after = inner[idx + marker.len ..];
    const close = std.mem.lastIndexOfScalar(u8, after, '"') orelse return .{ .field = inner, .default = null };
    const field = std.mem.trimEnd(u8, inner[0..idx], " \t");
    return .{ .field = field, .default = after[0..close] };
}

/// Identifier for `comment.markerForExtension`: a dotfile with no further dot
/// (`.zshrc`) or an un-dotted basename (`Dockerfile`) is itself; otherwise the
/// trailing extension (`.lua`). Mirrors `source.axes`'s private helper of the
/// same name and contract.
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

const header_scan_lines: usize = 16;

const ScriptHead = struct {
    when: ?[]const u8 = null,
    needs: ?[]const u8 = null,
};

/// Scan a script's leading comment block (shebang/blank/`#`-comment lines, up
/// to `header_scan_lines`, stopping at the first real content line) for a
/// `# mox: when <expr>` and a `# mox: needs <name>...` line. Unlike
/// `apply.run_scripts`'s single-directive header scan, this keeps scanning
/// after finding one so the other is not missed; only the FIRST occurrence of
/// each is kept. CRLF-tolerant: a trailing `\r` is trimmed with the rest of
/// the line's surrounding whitespace.
fn scanScriptHead(content: []const u8) ScriptHead {
    var result: ScriptHead = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    var scanned: usize = 0;
    var first = true;
    while (lines.next()) |raw| {
        if (scanned >= header_scan_lines) break;
        scanned += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        const was_first = first;
        first = false;
        if (was_first and std.mem.startsWith(u8, line, "#!")) continue;
        if (line.len == 0) continue;
        if (line[0] != '#') break;

        var rest = std.mem.trimStart(u8, line[1..], " \t");
        if (!std.mem.startsWith(u8, rest, "mox:")) continue;
        rest = std.mem.trimStart(u8, rest[4..], " \t");

        if (result.when == null and std.mem.startsWith(u8, rest, "when")) {
            const after = rest[4..];
            if (!wordContinues(after)) {
                result.when = std.mem.trim(u8, after, " \t");
                continue;
            }
        }
        if (result.needs == null and std.mem.startsWith(u8, rest, "needs")) {
            const after = rest[5..];
            if (!wordContinues(after)) {
                result.needs = std.mem.trim(u8, after, " \t");
                continue;
            }
        }
    }
    return result;
}

/// True when `after` starts with a character that would make the preceding
/// keyword part of a longer word (`whenever`, `needsomething`) rather than a
/// directive followed by its argument or end-of-line.
fn wordContinues(after: []const u8) bool {
    return after.len != 0 and (std.ascii.isAlphanumeric(after[0]) or after[0] == '_');
}

/// Parse a `# mox: needs` line's argument into whitespace-separated names.
/// An empty (or all-whitespace) argument is a valid explicit-empty list.
fn parseNeeds(arena: std.mem.Allocator, raw: []const u8) (DiscoverError || std.mem.Allocator.Error)![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |tok| {
        if (!source.tuple.isValidAxisName(tok)) return error.InvalidNeedsName;
        try names.append(arena, try arena.dupe(u8, tok));
    }
    return names.toOwnedSlice(arena);
}

fn isFactTokenChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Every maximal run of `[A-Z0-9_]` in `content` that starts with `MOX_FACT_`
/// and has at least one character past it, sorted and deduped. A run breaks
/// at any other byte (lowercase, punctuation, `$`, `{`, whitespace, `\r`),
/// so this is naturally CRLF-tolerant and finds a token however it is
/// referenced (`$MOX_FACT_X`, `${MOX_FACT_X}`, `%MOX_FACT_X%`, ...).
fn scanMoxFactTokens(arena: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    const prefix = "MOX_FACT_";
    var set = std.StringHashMap(void).init(arena);
    var i: usize = 0;
    while (i < content.len) {
        if (!isFactTokenChar(content[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < content.len and isFactTokenChar(content[i])) : (i += 1) {}
        const run = content[start..i];
        if (std.mem.startsWith(u8, run, prefix) and run.len > prefix.len) {
            try set.put(run, {});
        }
    }
    return sortedKeys(arena, &set);
}

/// Project a dimension name onto its `MOX_FACT_<NAME>` environment token,
/// mirroring `apply.run_scripts.buildScriptEnv`'s sanitize rule (alnum
/// uppercased, anything else -> `_`) so a scanned token can be matched back
/// to the dimension that would produce it.
fn factEnvName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const prefix = "MOX_FACT_";
    const out = try arena.alloc(u8, prefix.len + name.len);
    @memcpy(out[0..prefix.len], prefix);
    for (name, 0..) |c, i| {
        out[prefix.len + i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
    }
    return out;
}

fn sortedKeys(arena: std.mem.Allocator, set: *const std.StringHashMap(void)) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(arena, k.*);
    const slice = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

/// Absolute path to `<tmp>/<sub>` via the canonical `<cwd>/.zig-cache/tmp/<id>`
/// location other source-tree tests share.
fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    if (sub.len == 0) return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

fn findDim(d: Discovery, name: []const u8) ?Dimension {
    for (d.dimensions) |dim| {
        if (std.mem.eql(u8, dim.name, name)) return dim;
    }
    return null;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

test "discover: value-compared role from a when gate, with observed value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when holt_backend=gdrive\nx = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expect(!dim.roles.captured);
    try std.testing.expect(!dim.roles.presence);
    try std.testing.expectEqual(@as(usize, 1), dim.observed_values.len);
    try std.testing.expectEqualStrings("gdrive", dim.observed_values[0]);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.source_count);
}

test "discover: presence-only role from a bare when name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when signing_key\nx = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "signing_key").?;
    try std.testing.expect(dim.roles.presence);
    try std.testing.expect(!dim.roles.value_compared);
    try std.testing.expect(!dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), dim.observed_values.len);
}

test "discover: captured role with a default, unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "email = <machine.email | default \"me@example.com\">\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "email").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(!dim.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), dim.capture_defaults.len);
    try std.testing.expectEqualStrings("me@example.com", dim.capture_defaults[0]);
    // Unconditioned occurrence -> no asking condition.
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a .d overlay filename tuple is value-compared" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/profile=work", "[user]\n  name = w\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "profile").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqualStrings("work", dim.observed_values[0]);
}

test "discover: a Cat B region fragment is value-compared" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/kind.lua", "local M = {}\nreturn M\n");
    try writeFile(io, tmp.dir, "src/kind.lua.d/profile/work.lua", "M.kind = \"work\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "profile").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqualStrings("work", dim.observed_values[0]);
}

test "discover: a data-driven `name = <var>.field` row predicate is value-compared with an empty observed set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\nname = \"fd\"\nwhen = \"gdrive\"\n");
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\" where holt_backend=entry.when\n# alias <entry.name>\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expect(!dim.roles.captured);
    try std.testing.expect(!dim.roles.presence);
    try std.testing.expectEqual(@as(usize, 0), dim.observed_values.len);
}

test "discover: `bound <var>.field` contributes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "data/ids.toml", "[[ids]]\nkey = \"gopath\"\n");
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when profile=work\nx = 1\n# mox: end\n" ++
            "# mox: for entry in \"data/ids.toml\" where bound entry.key\n# x <entry.key>\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    // The sibling `profile=work` gate proves the file parsed successfully
    // (a parse failure would silently drop everything, including this).
    try std.testing.expect(findDim(d, "profile") != null);
    try std.testing.expect(findDim(d, "gopath") == null);
}

test "discover: exclusion -- built-ins, open axes, reserved names never become dimensions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.gitconfig",
        "# mox: when os=darwin\nx = 1\n# mox: end\n" ++
            "# mox: when tool=fd\ny = 1\n# mox: end\n" ++
            "z = <machine.hostname>\n" ++
            "w = <machine.tool_path.rg>\n" ++
            "# mox: when signing_key\nv = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    for ([_][]const u8{ "os", "tool", "hostname", "tool_path", "env" }) |n| {
        try std.testing.expect(findDim(d, n) == null);
    }
    // signing_key is a genuine presence-only dimension, unaffected by the
    // exclusion sweep.
    try std.testing.expect(findDim(d, "signing_key") != null);
}

test "discover: a data/facts.toml-declared name is excluded even when captured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "data/facts.toml", "[[facts]]\nname = \"brew_prefix\"\ncandidates = [\"/opt/homebrew\"]\n");
    try writeFile(io, tmp.dir, "src/.zshrc", "export PATH=<machine.brew_prefix>/bin\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "brew_prefix") == null);
}

test "discover: conditional capture -- asking_condition matches the enclosing gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.gitconfig",
        "# mox: when holt_backend=gdrive\naccount = <machine.gdrive_account>\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "gdrive_account").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("holt_backend", cond.eq.axis);
    try std.testing.expectEqualStrings("gdrive", cond.eq.value);
}

test "discover: the same name gate-compared elsewhere yields a null asking_condition" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.gitconfig",
        "# mox: when holt_backend=gdrive\nx = <machine.holt_backend>\n# mox: end\n" ++
            "# mox: when holt_backend=icloud\ny = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: multiple captures under different gates OR together" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.config/app/config.toml",
        "# mox: when profile=work\nid = <machine.workspace_id>\n# mox: end\n" ++
            "# mox: when profile=personal\nid2 = <machine.workspace_id>\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "workspace_id").?;
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .or_);

    var bindings = std.StringHashMap([]const u8).init(a);
    var bindings_r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &bindings_r));
    try bindings.put("profile", "personal");
    try std.testing.expect(dsl.axis.evaluate(cond, &bindings_r));
    try bindings.put("profile", "other");
    try std.testing.expect(!dsl.axis.evaluate(cond, &bindings_r));
}

test "discover: nested when regions AND their conditions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.gitconfig",
        "# mox: when profile=work\n" ++
            "# mox: when holt_backend=gdrive\n" ++
            "account = <machine.gdrive_account>\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "gdrive_account").?;
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .and_);

    var bindings = std.StringHashMap([]const u8).init(a);
    var bindings_r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "work");
    try bindings.put("holt_backend", "gdrive");
    try std.testing.expect(dsl.axis.evaluate(cond, &bindings_r));
    try bindings.put("holt_backend", "icloud");
    try std.testing.expect(!dsl.axis.evaluate(cond, &bindings_r));
}

test "discover: a quoted UTF-8 value is observed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "Tokyo" in kanji, as raw UTF-8 bytes.
    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when locale=\"\xe6\x9d\xb1\xe4\xba\xac\"\nx = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "locale").?;
    try std.testing.expectEqual(@as(usize, 1), dim.observed_values.len);
    try std.testing.expectEqualStrings("\xe6\x9d\xb1\xe4\xba\xac", dim.observed_values[0]);
}

test "discover: a script's MOX_FACT token in a comment is scanned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/00-brew.sh",
        "#!/bin/sh\n# uses $MOX_FACT_PROFILE to pick a bundle\necho \"$MOX_FACT_PROFILE\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.scripts.len);
    const s = d.scripts[0];
    try std.testing.expectEqualStrings("scripts/pre/00-brew.sh", s.path);
    try std.testing.expect(s.needs == null);
    try std.testing.expectEqual(@as(usize, 1), s.scanned_tokens.len);
    try std.testing.expectEqualStrings("MOX_FACT_PROFILE", s.scanned_tokens[0]);
}

test "discover: a script's `# mox: needs` overrides the token scan, and links provenance" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/01-onepassword.sh",
        "#!/bin/sh\n# mox: needs onepassword_account\n" ++
            "echo \"$MOX_FACT_PROFILE would be scanned but is overridden\"\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc", "op = <machine.onepassword_account>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const s = d.scripts[0];
    try std.testing.expect(s.needs != null);
    try std.testing.expectEqual(@as(usize, 1), s.needs.?.len);
    try std.testing.expectEqualStrings("onepassword_account", s.needs.?[0]);
    // The scan still records the tokens present in the text...
    try std.testing.expect(containsStr(s.scanned_tokens, "MOX_FACT_PROFILE"));

    // ...but `needs` is what links provenance: `profile` never appears in
    // needing_scripts because `needs` replaced the token scan for linkage.
    const dim = findDim(d, "onepassword_account").?;
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/01-onepassword.sh", dim.provenance.needing_scripts[0]);
}

test "discover: an empty `# mox: needs` line declares an explicit empty list" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/post/reload.sh", "#!/bin/sh\n# mox: needs\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const s = d.scripts[0];
    try std.testing.expect(s.needs != null);
    try std.testing.expectEqual(@as(usize, 0), s.needs.?.len);
}

test "discover: a malformed `# mox: needs` name is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/bad.sh", "#!/bin/sh\n# mox: needs Not-Valid\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    try std.testing.expectError(error.InvalidNeedsName, discover(a, io, repo));
}

test "discover: integration -- gdrive_account gated, 1Password pair gated on profile=work, profile compared+captured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.config/holt/config.toml",
        "backend = \"<machine.holt_backend | default \\\"personal\\\">\"\n" ++
            "# mox: when holt_backend=gdrive\naccount = <machine.gdrive_account>\n# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "src/.config/op/plugins.sh",
        "# mox: when profile=work\n" ++
            "export OP_ACCOUNT=<machine.op_account>\n" ++
            "export OP_VAULT=<machine.op_vault | default \"Personal\">\n" ++
            "# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when profile=work\n" ++
            "x = 1\n" ++
            "# mox: end\n" ++
            "kind = <machine.profile | default \"personal\">\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const gdrive = findDim(d, "gdrive_account").?;
    try std.testing.expect(gdrive.roles.captured);
    try std.testing.expect(!gdrive.roles.value_compared);
    var b1 = std.StringHashMap([]const u8).init(a);
    var r1: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &b1 } };
    try b1.put("holt_backend", "icloud");
    try std.testing.expect(!dsl.axis.evaluate(gdrive.asking_condition.?, &r1));
    try b1.put("holt_backend", "gdrive");
    try std.testing.expect(dsl.axis.evaluate(gdrive.asking_condition.?, &r1));

    const op_account = findDim(d, "op_account").?;
    try std.testing.expect(op_account.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), op_account.capture_defaults.len);
    var b2 = std.StringHashMap([]const u8).init(a);
    var r2: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &b2 } };
    try b2.put("profile", "personal");
    try std.testing.expect(!dsl.axis.evaluate(op_account.asking_condition.?, &r2));
    try b2.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(op_account.asking_condition.?, &r2));

    const op_vault = findDim(d, "op_vault").?;
    try std.testing.expectEqualStrings("Personal", op_vault.capture_defaults[0]);

    // profile: compared as "work" only, captured with default "personal".
    const profile = findDim(d, "profile").?;
    try std.testing.expect(profile.roles.value_compared);
    try std.testing.expect(profile.roles.captured);
    try std.testing.expectEqual(@as(usize, 1), profile.observed_values.len);
    try std.testing.expectEqualStrings("work", profile.observed_values[0]);
    try std.testing.expectEqual(@as(usize, 1), profile.capture_defaults.len);
    try std.testing.expectEqualStrings("personal", profile.capture_defaults[0]);
    // Gate-derived occurrence makes this unconditioned.
    try std.testing.expect(profile.asking_condition == null);
}

test "discover: an empty repo (no src, no scripts) yields no dimensions and no scripts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, ".");
    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 0), d.dimensions.len);
    try std.testing.expectEqual(@as(usize, 0), d.scripts.len);
}
