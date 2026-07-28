//! Config-space discovery: a dedicated pre-interview pass that scans a repo's
//! `src/` tree and `scripts/pre|post` trees for every custom fact ("dimension")
//! the repo's sources actually consume, instead of a hand-maintained schema
//! file. Pure function of (repo_dir, io, alloc): no state is written. Wired
//! into `apply` (before the interview) and `mox facts`.
//!
//! A dimension is discovered through three channels, at any nesting depth a
//! directive's body reaches (a `# mox: when` nested inside a `when`/`for`/
//! `append`/... body is honored by compose's own recursive emit, so this scan
//! follows it there too):
//!   - value-compared: `name=value` in a gate, region, whole-file gate, overlay
//!     filename tuple, generator gate, or script `# mox: when` head, with the
//!     observed literal value set (a `name = <var>.field` row predicate is
//!     value-compared with an EMPTY observed set; `bound <var>.field` names no
//!     axis and contributes nothing; a bare, undotted `present`/`has`/`eq`
//!     inside a for-loop row predicate is a machine-axis reference exactly
//!     when the row-expr grammar itself treats it as one -- its head names no
//!     enclosing loop frame -- and is recorded the same way).
//!   - captured: `<machine.NAME>` occurrences anywhere compose would actually
//!     emit them -- a managed file's base content (recursing into every
//!     nested `# mox: when`/`for` region), a directive's literal body, and
//!     the fragment file an `include`/`append`/`prepend`/`replace`/`from`
//!     target or a Cat B region names -- each with its `| default`.
//!   - presence-only: a bare `when NAME` gate.
//!
//! Every occurrence of every role -- value-compared, presence, or captured
//! alike -- carries an asking condition: the conjunction of enclosing
//! conditions that are both cleanly axis-expressible and required for
//! emission, AND its conjunction-sibling predicates within the same `and`
//! (its own atom excluded; a sibling under an `or` contributes nothing, an
//! atom there can be demanded alone). A negated-gate body contributes
//! `not <gate>`; a from-fallback body, a for-loop's per-row emission, and a
//! tuple-matched fragment pick are not cleanly expressible and contribute
//! nothing -- over-asking is safe, under-asking is not. A dimension's
//! `asking_condition` is the OR of every occurrence's condition, null the
//! moment any single occurrence is itself unconditioned.
//!
//! Built-ins, the open probe axes, reserved axis names, and `data/facts.toml`-
//! derived names are excluded by category, never by a hand-written name list.
//!
//! A `# mox: default NAME="VALUE"` line directive (found at the same
//! nesting depths, unconditioned -- its enclosing gates are irrelevant, it
//! is a repo-level statement) declares an interview default for `NAME`; it
//! is not itself a discovery channel (a default alone consumes nothing) and
//! only attaches to a dimension one of the three channels above already
//! made real, surfacing as `Dimension.declared_defaults`.
//!
//! Structural anomalies are loud per-site diagnostics, never fatal: a
//! `# mox: default` naming disagreeing values, naming an excluded name, or
//! naming a fact no channel above made a dimension (`Discovery.
//! default_diagnostics`); a `<machine.NAME>` capture or `# mox: needs NAME`
//! outside the fact-name charset (`Discovery.diagnostics`, the latter also
//! marking its `ScriptRecord.needs_unparseable`). The offending site is
//! skipped and scanning continues -- `discover` itself only fails on an
//! actual OOM/IO-class error, or a structurally invalid source tree it
//! degrades to "nothing found" over rather than pre-empting the richer
//! report `apply`'s own source-tree walk produces for the same file. That
//! degrade is recorded on `Discovery.tree_error` rather than left silent:
//! `apply` ignores it (its own later walk reports the same failure better),
//! `mox facts` -- which has no such backstop -- refuses on it instead of
//! reporting an empty config space as if the tree had parsed cleanly.

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
    /// The declared interview default from `# mox: default NAME="VALUE"`,
    /// when the repo's `default` directives for this name agree: a
    /// single-element slice holding that value, or empty when no `default`
    /// directive names this dimension. Never more than one element --
    /// conflicting declarations for the same name resolve to no value here
    /// (see `Discovery.default_diagnostics`) rather than an arbitrary pick.
    declared_defaults: []const []const u8,
    /// The OR of every occurrence's condition, across ALL roles
    /// (value-compared, presence, captured alike): each occurrence's own
    /// enclosing gates conjoined with its conjunction-sibling predicates
    /// (its own atom excluded). Null the moment any single occurrence is
    /// itself unconditioned -- so a fact compared or captured unconditionally
    /// even once, anywhere in the repo, is always asked (conservative-ask:
    /// over-asking is safe, under-asking is the defect class).
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
    /// such directive (or its directive failed to parse, see
    /// `needs_unparseable`); an empty (non-null) slice when it declares no
    /// facts needed. When non-null, REPLACES `scanned_tokens` as this
    /// script's effective consumption set.
    needs: ?[]const []const u8,
    /// True when the script has a `# mox: needs` line whose name failed the
    /// fact-name charset (`Diagnostic.needs_name`, printed for it). `needs`
    /// is left null in that case rather than a guessed partial list -- the
    /// script's contract is unknowable, so the script-contract check blocks
    /// it outright on this marker rather than falling back to a token scan.
    needs_unparseable: bool = false,
};

/// A per-site scan anomaly worth surfacing loudly even though it doesn't
/// fail the whole discovery run: a malformed name is ignored at its own
/// site, and scanning continues everywhere else.
pub const Diagnostic = union(enum) {
    /// A `<machine.NAME>` capture whose NAME failed the fact-name charset
    /// (`[a-z][a-z0-9_]*`): recorded nowhere as a dimension.
    capture_name: struct {
        path: []const u8,
        name: []const u8,
    },
    /// A `# mox: needs NAME...` head directive whose NAME failed the
    /// fact-name charset. The offending script's own `ScriptRecord` carries
    /// `needs_unparseable = true` (its contract is unknowable, so the
    /// script-contract check blocks it outright on this marker rather than
    /// falling back to a token scan); `needs` is left null on it, same as a
    /// script with no `needs` line at all.
    needs_name: struct {
        path: []const u8,
        name: []const u8,
        line: u32,
    },
};

/// A `# mox: default NAME="VALUE"` anomaly worth surfacing without failing
/// the whole discovery run -- neither aborts discovery, matching
/// `Diagnostic`'s own "loud, never silently dropped" contract.
pub const DefaultDiagnostic = union(enum) {
    /// Two `# mox: default` directives named the same fact with different
    /// values.
    conflict: struct {
        name: []const u8,
        first_source: []const u8,
        first_value: []const u8,
        second_source: []const u8,
        second_value: []const u8,
    },
    /// A `# mox: default` directive names a fact no source in the repo
    /// otherwise compares, captures, or tests for presence -- a default
    /// alone consumes nothing, so no dimension is created for it either.
    /// Creating one anyway would make `doctor`'s stale-fact check wrongly
    /// treat an otherwise-unconsumed bound fact as used, purely because
    /// someone once declared a default for it.
    unclaimed: struct {
        name: []const u8,
        source: []const u8,
    },
    /// A `# mox: default` directive names a built-in, open-probe-axis,
    /// reserved-axis, or `data/facts.toml`-derived name -- excluded by
    /// category the same way a discovery occurrence would be, but loud
    /// rather than silently dropped since a default declaration is a
    /// deliberate repo-level statement.
    reserved: struct {
        name: []const u8,
        source: []const u8,
    },
};

/// Print every discovery anomaly to `out`, each line prefixed with
/// `prefix` (`"mox apply: "` for apply, `""` for bare `mox facts`, matching
/// `interview.writeUnboundNotice`'s own prefix contract). Shared between
/// apply and `mox facts` so a repo's structural anomalies read identically
/// wherever discovery runs.
pub fn writeDiagnostics(
    out: *std.Io.Writer,
    prefix: []const u8,
    diagnostics: []const Diagnostic,
    default_diagnostics: []const DefaultDiagnostic,
) !void {
    for (diagnostics) |d| switch (d) {
        .capture_name => |c| try out.print(
            "{s}{s}: <machine.{s}> is not a valid fact name; ignored\n",
            .{ prefix, c.path, c.name },
        ),
        .needs_name => |n| try out.print(
            "{s}{s}:{d}: `# mox: needs {s}` is not a valid fact name; ignored\n",
            .{ prefix, n.path, n.line, n.name },
        ),
    };
    for (default_diagnostics) |dd| switch (dd) {
        .conflict => |c| try out.print(
            "{s}conflicting `# mox: default` for \"{s}\": {s}=\"{s}\" vs {s}=\"{s}\"\n",
            .{ prefix, c.name, c.first_source, c.first_value, c.second_source, c.second_value },
        ),
        .unclaimed => |u| try out.print(
            "{s}`# mox: default {s}=...` in {s} names a fact nothing else in the repo consumes; ignored\n",
            .{ prefix, u.name, u.source },
        ),
        .reserved => |r| try out.print(
            "{s}`# mox: default {s}=...` in {s} names a reserved/built-in fact name; ignored\n",
            .{ prefix, r.name, r.source },
        ),
    };
}

pub const Discovery = struct {
    /// Every discovered dimension, sorted by name.
    dimensions: []const Dimension,
    /// Every scanned script, in scan order (scripts/pre then scripts/post,
    /// each subtree in sorted directory order).
    scripts: []const ScriptRecord,
    /// Capture-charset anomalies, in scan order.
    diagnostics: []const Diagnostic = &.{},
    /// `# mox: default` conflict/unclaimed anomalies, in first-encounter
    /// order by name.
    default_diagnostics: []const DefaultDiagnostic = &.{},
    /// Set when the `src/` tree walk failed on something other than OOM (a
    /// reserved axis name, a malformed ownership declaration, ...): the
    /// error name `source.tree.walk` returned. Dimension content still
    /// degrades to "nothing found" in this case (see `discover`'s doc
    /// comment) rather than the caller getting a half-scanned tree with no
    /// indication anything was wrong -- `apply` ignores this signal (its own
    /// later `walkDiag` call reports the same failure with the offending
    /// file and a richer message); `mox facts`, which has no such backstop,
    /// checks it and refuses instead of silently reporting an empty config
    /// space.
    tree_error: ?anyerror = null,
};

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
        .diagnostics = .empty,
        .declared_defaults = .empty,
        .default_diagnostics = .empty,
    };

    for (try derived_facts.declaredNames(arena, io, repo_dir, "")) |n| {
        try self.derived_names.put(n, {});
    }

    // A structurally invalid source tree (bad attributes.toml, an illegal
    // own/check declaration, a reserved axis name on a path= overlay, ...)
    // is the richer `source.tree.walkDiag` call further into `apply`'s own
    // pipeline's problem to diagnose with the offending file and site;
    // discovery degrades to "nothing found" on any such error here rather
    // than pre-empting that later, better report with a bare error name.
    // Only OOM is worth failing discovery itself over.
    const src_dir = try std.fs.path.join(arena, &.{ repo_dir, "src" });
    var tree_error: ?anyerror = null;
    const tree = source.tree.walk(arena, io, src_dir, "") catch |e| switch (e) {
        error.OutOfMemory => return e,
        // No `src/` at all is a fresh/empty repo, not a structural problem
        // (this function's own doc comment: "a missing src/ ... is not an
        // error") -- degrades silently, same as before this fix.
        error.FileNotFound => source.tree.ManagedTree{ .files = &.{} },
        else => blk: {
            tree_error = e;
            break :blk source.tree.ManagedTree{ .files = &.{} };
        },
    };
    for (tree.files) |file| try self.scanManagedFile(file);

    inline for (.{ "pre", "post" }) |stage| {
        const abs = try std.fs.path.join(arena, &.{ repo_dir, "scripts", stage });
        try self.scanScriptsTree(abs, "scripts/" ++ stage);
    }

    var result = try self.finalize();
    result.tree_error = tree_error;
    return result;
}

/// Per-dimension scan state, held in `Discoverer.dims` keyed by name.
const DimWork = struct {
    roles: Roles = .{},
    observed_values: std.StringHashMap(void),
    capture_defaults: std.StringHashMap(void),
    /// One entry per occurrence -- value-compared, presence, or captured
    /// alike -- of its condition, or null when that occurrence is itself
    /// unconditioned. Order does not matter (OR is commutative).
    occurrence_conditions: std.ArrayList(?*const AxisExpr),
    sources: std.StringHashMap(void),
};

/// One collected `# mox: default NAME="VALUE"` occurrence, before conflict
/// resolution groups them by name.
const RawDefault = struct {
    name: []const u8,
    value: []const u8,
    source: []const u8,
};

const Discoverer = struct {
    arena: std.mem.Allocator,
    io: Io,
    dims: std.StringHashMap(DimWork),
    derived_names: std.StringHashMap(void),
    scripts: std.ArrayList(ScriptRecord),
    diagnostics: std.ArrayList(Diagnostic),
    /// Every `# mox: default` occurrence collected during the tree scan, at
    /// whatever position the traversal reached it -- unconditioned by
    /// construction, since the collection call never consults a gate stack.
    declared_defaults: std.ArrayList(RawDefault),
    /// `# mox: default` anomalies: a reserved-name occurrence is appended
    /// here directly at scan time (`recordDeclaredDefault`); conflict/
    /// unclaimed occurrences are appended once declared_defaults is grouped
    /// at `finalize` time (`resolveDeclaredDefaults`). Both land in the same
    /// list so `Discovery.default_diagnostics` needs no later merge.
    default_diagnostics: std.ArrayList(DefaultDiagnostic),

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
                .occurrence_conditions = .empty,
                .sources = std.StringHashMap(void).init(self.arena),
            };
        }
        return gop.value_ptr;
    }

    /// A `# mox: needs NAME` reference that names no dimension any other
    /// channel already made real registers `NAME` as a scripts-only
    /// dimension -- free-form (no role) and unconditioned (an unconditioned
    /// occurrence, same treatment as a top-level unguarded capture), so the
    /// interview asks it like any other. An excluded name (built-in, open
    /// axis, reserved, `data/facts.toml`-derived) registers nothing, same as
    /// `dimFor` everywhere else -- it already has its own resolution path,
    /// not an interview question. A name that is ALREADY a real dimension via
    /// some other channel is left untouched: `needingScripts` links this
    /// script to it by name alone at `finalize` time, and pushing another
    /// occurrence here would wrongly widen an existing conditioned
    /// dimension's asking condition to unconditioned.
    fn registerNeedsName(self: *Discoverer, name: []const u8) !void {
        if (self.dims.contains(name)) return;
        const dw = (try self.dimFor(name)) orelse return;
        try dw.occurrence_conditions.append(self.arena, null);
    }

    fn isExcluded(self: *Discoverer, name: []const u8) bool {
        return state.isBuiltinField(name) or
            source.axes.isReservedAxisName(name) or
            self.derived_names.contains(name);
    }

    // -- axis (value-compared / presence) scanning --------------------------

    /// Record every atom in `expr`, each with its own occurrence condition:
    /// `ctx` (the enclosing gates already accumulated) AND, for an atom
    /// nested under an `and_`, its conjunction-sibling atoms at every level
    /// (its own atom excluded) -- an atom nested under an `or_` inherits
    /// `ctx` unchanged, since a disjunction's other branch is never required
    /// for THIS branch's own demand (the conservative-ask law: over-asking
    /// is safe, so an atom under an `or` with no enclosing gate is
    /// unconditioned). This applies uniformly to every role (value-compared,
    /// presence): the comparison is no longer assumed to be its own,
    /// unconditioned demand -- a gate or comparison nested inside another or
    /// conjoined with a sibling predicate is exactly as conditioned as a
    /// capture would be at the same position.
    fn recordAxisExpr(self: *Discoverer, expr: *const AxisExpr, source_key: []const u8, ctx: ?*const AxisExpr) !void {
        switch (expr.*) {
            .eq => |e| {
                if (try self.dimFor(e.axis)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.observed_values.put(try self.arena.dupe(u8, e.value), {});
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            .present => |n| {
                if (try self.dimFor(n)) |dw| {
                    dw.roles.presence = true;
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            .not => |inner| try self.recordAxisExpr(inner, source_key, ctx),
            .and_ => |a| {
                try self.recordAxisExpr(a.left, source_key, try combineAndSibling(self.arena, ctx, a.right));
                try self.recordAxisExpr(a.right, source_key, try combineAndSibling(self.arena, ctx, a.left));
            },
            .or_ => |o| {
                try self.recordAxisExpr(o.left, source_key, ctx);
                try self.recordAxisExpr(o.right, source_key, ctx);
            },
        }
    }

    /// `ref`'s a machine-axis reference, not a row reference, exactly when
    /// `row_expr.evaluate` would treat it as one: it carries no `.` (so it
    /// cannot be a `<var>.<field>` row lookup) AND its head does not name an
    /// enclosing loop frame (`loop_vars`) -- a bare `entry` inside a `for
    /// entry in ...` is that row's own presence check, not an axis, exactly
    /// as `row_expr.presentRef`/`memberRef` resolve it against the scope
    /// before ever falling back to a machine-axis lookup.
    fn bareAxisRef(ref: []const u8, loop_vars: []const []const u8) bool {
        if (std.mem.indexOfScalar(u8, ref, '.') != null) return false;
        for (loop_vars) |v| {
            if (std.mem.eql(u8, v, ref)) return false;
        }
        return true;
    }

    /// `ctx` is the enclosing-gate condition (same contract as
    /// `recordAxisExpr`'s `ctx`), threaded through unchanged by `and_`/`or_`/
    /// `not`: a row predicate's own conjunction siblings are NOT folded into
    /// a leaf's condition here, unlike `recordAxisExpr` -- they evaluate
    /// per-row against a loop frame at compose time (a `<var>.field`
    /// comparison, not a static axis), so a sibling row predicate has no
    /// `AxisExpr` shape to conjoin with `ctx` in the first place. Only the
    /// machine-axis leaves this grammar can still produce (`present`/`has`/
    /// `eq`/`axis_with_field` on a bare, undotted ref) get an occurrence
    /// condition at all, and it is exactly `ctx` -- over-asking-safe, same
    /// as this grammar's condition contract before this fix, just now
    /// actually wired to the enclosing gate stack instead of always null.
    fn recordRowExpr(self: *Discoverer, expr: *const dsl.ast.RowExpr, source_key: []const u8, loop_vars: []const []const u8, ctx: ?*const AxisExpr) !void {
        switch (expr.*) {
            // `<axis>=<var>.field`: the axis name is static even though the
            // compared value is a row field known only at compose time, so it
            // is value-compared with an empty observed set.
            .axis_with_field => |a| {
                if (try self.dimFor(a.axis)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            // `bound <var>.field` names no axis statically (the bound name is
            // itself a row field). A DOTTED `present`/`has`/`eq` ref is a row
            // field too. An UNDOTTED one, though, is exactly what
            // `row_expr.evaluate` falls back to a machine-axis lookup for
            // (`axis_mod.presentMatch`/`eqMatch`) once no enclosing loop frame
            // matches its head -- so it is recorded the same way the axis
            // grammar's own `present`/`eq` are.
            .bound => {},
            .present => |ref| {
                if (!bareAxisRef(ref, loop_vars)) return;
                if (try self.dimFor(ref)) |dw| {
                    dw.roles.presence = true;
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            .has => |h| {
                if (!bareAxisRef(h.ref, loop_vars)) return;
                if (try self.dimFor(h.ref)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.observed_values.put(try self.arena.dupe(u8, h.value), {});
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            .eq => |e| {
                if (!bareAxisRef(e.ref, loop_vars)) return;
                if (try self.dimFor(e.ref)) |dw| {
                    dw.roles.value_compared = true;
                    try dw.observed_values.put(try self.arena.dupe(u8, e.value), {});
                    try dw.sources.put(source_key, {});
                    try dw.occurrence_conditions.append(self.arena, ctx);
                }
            },
            .not => |inner| try self.recordRowExpr(inner, source_key, loop_vars, ctx),
            .and_ => |a| {
                try self.recordRowExpr(a.left, source_key, loop_vars, ctx);
                try self.recordRowExpr(a.right, source_key, loop_vars, ctx);
            },
            .or_ => |o| {
                try self.recordRowExpr(o.left, source_key, loop_vars, ctx);
                try self.recordRowExpr(o.right, source_key, loop_vars, ctx);
            },
        }
    }

    /// A directive's own axis/row expressions. Called by `scanBody` at every
    /// nesting depth it visits -- a nested `# mox: when` inside a
    /// `when`/`for`/`append`/... body is honored by compose's own recursive
    /// emit, so a fact compared only there is as real a dimension as one
    /// compared at the top level. `nest.gate_stack`'s conjunction (`ctx`)
    /// becomes the base occurrence condition for every atom this directive's
    /// own axis/row expression records -- a directive's `when` a level
    /// deeper than its enclosing gate carries that outer gate too, same as a
    /// capture at the same position already did.
    fn recordDirectiveAxes(self: *Discoverer, d: dsl.ast.Directive, source_key: []const u8, nest: Nest) !void {
        const ctx = try combineAnd(self.arena, nest.gate_stack);
        switch (d.kind) {
            .include => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx),
            .replace => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx),
            .append => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx),
            .prepend => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx),
            .remove => |k| try self.recordAxisExpr(k.when, source_key, ctx),
            .when_gate => |k| {
                if (k.when) |w|
                    try self.recordAxisExpr(w, source_key, ctx)
                else if (k.row_when) |r|
                    try self.recordRowExpr(r, source_key, nest.loop_vars, ctx);
            },
            .for_loop => |k| {
                // `when` is a pre-row axis gate: it evaluates before any row
                // is bound, so the loop's own variable is not in scope for
                // it, and `loop_vars` is passed unchanged. `where` evaluates
                // PER ROW, with the loop's own frame already bound
                // (composeGenerator/evalRow prepend `loop.variable` before
                // evaluating it) -- so a bare reference to the loop variable
                // itself (`where entry`) is that row's own presence check,
                // not a machine axis, exactly like `bareAxisRef` already
                // treats a loop variable appearing inside the loop's BODY.
                // Recording it with the enclosing (variable-less) `loop_vars`
                // would misread it as a phantom axis dimension.
                if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx);
                if (k.where) |r| {
                    const row_scope = try appendStr(self.arena, nest.loop_vars, k.variable);
                    try self.recordRowExpr(r, source_key, row_scope, ctx);
                }
            },
            .completions => |k| if (k.when) |w| try self.recordAxisExpr(w, source_key, ctx),
            .from, .secret, .default => {},
        }
    }

    /// Collect a `# mox: default NAME="VALUE"` directive, whatever position
    /// `scanBody` visited it at -- unconditioned by construction, since this
    /// never consults a gate stack: a declared default is a repo-level
    /// statement, its location's gates are irrelevant. A default naming an
    /// excluded (built-in, open-axis, reserved-axis, or
    /// `data/facts.toml`-derived) name is a loud, non-fatal diagnostic --
    /// `DefaultDiagnostic.reserved`, appended directly rather than deferred
    /// to `finalize` since exclusion is already known here -- and the
    /// declaration is dropped; scanning continues.
    fn recordDeclaredDefault(self: *Discoverer, d: dsl.ast.Directive, source_key: []const u8) !void {
        const def = switch (d.kind) {
            .default => |k| k,
            else => return,
        };
        if (self.isExcluded(def.name)) {
            try self.default_diagnostics.append(self.arena, .{ .reserved = .{
                .name = try self.arena.dupe(u8, def.name),
                .source = source_key,
            } });
            return;
        }
        try self.declared_defaults.append(self.arena, .{
            .name = try self.arena.dupe(u8, def.name),
            .value = try self.arena.dupe(u8, def.value),
            .source = source_key,
        });
    }

    /// An overlay/fragment filename tuple's pairs are always unconditioned
    /// occurrences: a `.d/os=linux` variant's existence demands `os`
    /// regardless of any gate (there is no enclosing `nest` at this scan
    /// site to inherit a condition from).
    fn recordTuple(self: *Discoverer, tuple: source.tree.AxisTuple, source_key: []const u8) !void {
        for (tuple.pairs) |p| {
            if (try self.dimFor(p.name)) |dw| {
                dw.roles.value_compared = true;
                try dw.observed_values.put(try self.arena.dupe(u8, p.value), {});
                try dw.sources.put(source_key, {});
                try dw.occurrence_conditions.append(self.arena, null);
            }
        }
    }

    // -- capture + nested-directive traversal --------------------------------

    /// Recursion state threaded through a file's directive tree. `gate_stack`
    /// holds every enclosing condition that is both cleanly axis-expressible
    /// and required for emission, innermost last -- a capture's condition is
    /// their conjunction (the paper's conservative-ask law: anything not
    /// cleanly expressible, e.g. which fragment a tuple match picks or a
    /// for-loop's per-row emission, contributes NOTHING rather than narrowing
    /// the condition, so under-asking never happens at the cost of an
    /// occasional unneeded ask). `loop_vars` holds every enclosing for-loop's
    /// variable name (innermost last); `in_for` mirrors `dsl.driver`'s
    /// in-loop parser selection -- true once inside a `for` body, where a
    /// standalone `when` uses the row-expr grammar instead of the axis one.
    const Nest = struct {
        file: source.tree.ManagedFile,
        marker: []const u8,
        gate_stack: []const *const AxisExpr,
        loop_vars: []const []const u8,
        in_for: bool,
        depth: u32,
    };

    /// Cap on `scanBody`/`recurseDirective` mutual recursion, mirroring
    /// `compose.catB`'s own nesting cap: real dotfile nesting is shallow, this
    /// only bounds a pathological or hostile structure so discovery
    /// terminates instead of overflowing the stack.
    const max_nest_depth: u32 = 128;

    /// Explicit error set for the mutually-recursive `scanBody` <->
    /// `recurseDirective` pair: an inferred set cannot resolve across the
    /// recursion cycle. Every read/parse failure on the path between them is
    /// already caught locally (a malformed nested body or missing fragment is
    /// skipped, not propagated) and every structural anomaly
    /// (`recordDeclaredDefault`'s reserved name included) is now a
    /// diagnostic rather than an error, so `OutOfMemory` is the only error
    /// either can actually return.
    const ScanError = std.mem.Allocator.Error;

    /// Parse `content` as one directive-tree scope (a whole file, or a nested
    /// region body) and scan its own content lines for `<machine.NAME>`
    /// captures at `nest.gate_stack`'s condition. Each directive is then
    /// dispatched to `recurseDirective`, which visits whichever nested bodies
    /// and fragment files compose would actually emit, with the condition
    /// each position warrants.
    fn scanBody(self: *Discoverer, content: []const u8, source_key: []const u8, nest: Nest) ScanError!void {
        if (nest.depth > max_nest_depth) return;
        const parsed = if (nest.in_for)
            dsl.driver.parseFileInLoop(self.arena, content, nest.marker, null) catch return
        else
            dsl.driver.parseFile(self.arena, content, nest.marker, null) catch return;

        for (parsed.directives) |d| try self.recordDirectiveAxes(d, source_key, nest);
        for (parsed.directives) |d| try self.recordDeclaredDefault(d, source_key);

        const condition = try combineAnd(self.arena, nest.gate_stack);
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (lineCovered(parsed.directives, line_no)) continue;
            try self.scanCapturesInLine(line, condition, source_key);
        }

        for (parsed.directives) |d| try self.recurseDirective(d, source_key, nest);
    }

    /// Visit whichever nested bodies and fragment files a directive's REAL
    /// compose-time emission reaches, at each position's asking condition: a
    /// body/fragment emitted unconditionally (or gated only by conditions
    /// already on `nest.gate_stack`) is scanned at `nest.gate_stack`
    /// unchanged; one gated on this directive's own `when` gets that gate
    /// pushed (positive for a fragment emitted when true, `not <gate>` for a
    /// literal body that is the false-branch fallback); one selected by TUPLE
    /// matching (a `from`/`replace ... from` pick) contributes nothing of its
    /// own -- its content is already covered unconditionally by the Cat B
    /// region scan in `scanManagedFile`, since which fragment compose picks
    /// is a tuple match, not a single axis equality.
    fn recurseDirective(self: *Discoverer, d: dsl.ast.Directive, source_key: []const u8, nest: Nest) ScanError!void {
        switch (d.kind) {
            .include => |inc| {
                const stack = try appendIf(self.arena, nest.gate_stack, inc.when);
                try self.scanFragmentTarget(nest.file, inc.path, stack, source_key);
            },
            .replace => |rep| {
                if (rep.from != null) {
                    try self.scanFlatText(rep.body, nest.gate_stack, source_key);
                } else if (rep.when) |w| {
                    const true_stack = try appendStack(self.arena, nest.gate_stack, w);
                    try self.scanFragmentTarget(nest.file, rep.path.?, true_stack, source_key);
                    const false_stack = try appendNot(self.arena, nest.gate_stack, w);
                    try self.scanFlatText(rep.body, false_stack, source_key);
                } else {
                    try self.scanFlatText(rep.body, nest.gate_stack, source_key);
                }
            },
            .append => |a| {
                try self.scanFlatText(a.body, nest.gate_stack, source_key);
                const stack = try appendIf(self.arena, nest.gate_stack, a.when);
                try self.scanFragmentTarget(nest.file, a.path, stack, source_key);
            },
            .prepend => |p| {
                const stack = try appendIf(self.arena, nest.gate_stack, p.when);
                try self.scanFragmentTarget(nest.file, p.path, stack, source_key);
                try self.scanFlatText(p.body, nest.gate_stack, source_key);
            },
            .remove => |r| {
                const false_stack = try appendNot(self.arena, nest.gate_stack, r.when);
                try self.scanFlatText(r.body, false_stack, source_key);
            },
            .from => |f| {
                try self.scanFlatText(f.body, nest.gate_stack, source_key);
            },
            .when_gate => |w| {
                if (nest.in_for) {
                    const inner: Nest = .{
                        .file = nest.file,
                        .marker = nest.marker,
                        .gate_stack = nest.gate_stack,
                        .loop_vars = nest.loop_vars,
                        .in_for = true,
                        .depth = nest.depth + 1,
                    };
                    try self.scanBody(w.body, source_key, inner);
                } else {
                    const stack = try appendStack(self.arena, nest.gate_stack, w.when.?);
                    const inner: Nest = .{
                        .file = nest.file,
                        .marker = nest.marker,
                        .gate_stack = stack,
                        .loop_vars = nest.loop_vars,
                        .in_for = false,
                        .depth = nest.depth + 1,
                    };
                    try self.scanBody(w.body, source_key, inner);
                }
            },
            .for_loop => |loop| {
                const loop_vars = try appendStr(self.arena, nest.loop_vars, loop.variable);
                const inner: Nest = .{
                    .file = nest.file,
                    .marker = nest.marker,
                    .gate_stack = nest.gate_stack,
                    .loop_vars = loop_vars,
                    .in_for = true,
                    .depth = nest.depth + 1,
                };
                try self.scanBody(loop.body_template, source_key, inner);
            },
            .completions, .secret, .default => {},
        }
    }

    /// Scan flat text -- a directive's own literal body, or a fragment file's
    /// content, neither of which compose ever re-parses for directives -- for
    /// `<machine.NAME>` captures at `stack`'s condition.
    fn scanFlatText(self: *Discoverer, text: []const u8, stack: []const *const AxisExpr, source_key: []const u8) !void {
        const condition = try combineAnd(self.arena, stack);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try self.scanCapturesInLine(line, condition, source_key);
    }

    /// Read and scan an `include`/`append`/`prepend`/`replace`'s fragment
    /// target, resolved the same way `compose.catB.emitFragmentByPath` does
    /// (relative to the base file's own `<base>.d/`). A missing fragment is
    /// apply's problem to report, not discovery's: skipped silently here, as
    /// every other unreadable file in this scan already is.
    fn scanFragmentTarget(
        self: *Discoverer,
        file: source.tree.ManagedFile,
        rel_path: []const u8,
        stack: []const *const AxisExpr,
        source_key: []const u8,
    ) !void {
        const overlay_dir = try std.fmt.allocPrint(self.arena, "{s}.d", .{file.source_base_abs});
        const abs = source.path.joinKeyOnto(self.arena, overlay_dir, rel_path) catch return;
        const content = Io.Dir.cwd().readFileAlloc(self.io, abs, self.arena, .limited(max_file_bytes)) catch return;
        try self.scanFlatText(content, stack, source_key);
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

            if (!source.tuple.isValidAxisName(field)) {
                try self.diagnostics.append(self.arena, .{ .capture_name = .{
                    .path = source_key,
                    .name = try self.arena.dupe(u8, field),
                } });
                continue;
            }

            const dw = (try self.dimFor(field)) orelse continue;
            dw.roles.captured = true;
            try dw.sources.put(source_key, {});
            try dw.occurrence_conditions.append(self.arena, condition);
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
                try dw.occurrence_conditions.append(self.arena, null);
            }
            for (rg.fragments) |fr| {
                try self.recordTuple(fr.tuple, source_key);
                // A fragment's own captures are scanned unconditionally: which
                // fragment compose picks is a tuple match, not a single axis
                // equality, so the conservative-ask law has it contribute no
                // condition of its own.
                const frag_content = Io.Dir.cwd().readFileAlloc(self.io, fr.path, self.arena, .limited(max_file_bytes)) catch continue;
                try self.scanFlatText(frag_content, &.{}, source_key);
            }
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

        try self.scanBody(content, source_key, .{
            .file = file,
            .marker = marker,
            .gate_stack = &.{},
            .loop_vars = &.{},
            .in_for = false,
            .depth = 0,
        });
    }

    // -- scripts tree -------------------------------------------------------

    /// Mirrors `apply.run_scripts.runStage`'s shape exactly: every top-level
    /// regular file, plus the files exactly ONE level inside a subdirectory
    /// whose name parses as an axis tuple (`os=linux`, `os=linux+profile=work`).
    /// A subdirectory that is not an axis tuple, or a file two or more levels
    /// deep, is never reached -- apply would never run it either, so scanning
    /// it here would surface directives (and their errors) apply itself never
    /// acts on.
    fn scanScriptsTree(self: *Discoverer, abs_dir: []const u8, rel_prefix: []const u8) !void {
        const entries = try source.dirent.sortedPath(self.arena, self.io, abs_dir, .{ .iterate = true });
        for (entries) |e| {
            const abs = try std.fs.path.join(self.arena, &.{ abs_dir, e.name });
            const rel = try source.path.joinKey(self.arena, &.{ rel_prefix, e.name });
            switch (e.kind) {
                .directory => {
                    if (isAxisTupleDirName(self.arena, e.name)) try self.scanGatedScriptsDir(abs, rel);
                },
                .file => try self.scanScriptFile(abs, rel),
                else => {},
            }
        }
    }

    /// The non-recursive second level `scanScriptsTree` descends into: every
    /// regular file directly inside a matching axis-tuple directory, no
    /// further subdirectories.
    fn scanGatedScriptsDir(self: *Discoverer, abs_dir: []const u8, rel_prefix: []const u8) !void {
        const entries = try source.dirent.sortedPath(self.arena, self.io, abs_dir, .{ .iterate = true });
        for (entries) |e| {
            if (e.kind != .file) continue;
            const abs = try std.fs.path.join(self.arena, &.{ abs_dir, e.name });
            const rel = try source.path.joinKey(self.arena, &.{ rel_prefix, e.name });
            try self.scanScriptFile(abs, rel);
        }
    }

    fn scanScriptFile(self: *Discoverer, abs_path: []const u8, rel_path: []const u8) !void {
        const content = Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.arena, .limited(max_script_bytes)) catch return;

        const head = scanScriptHead(content);
        if (head.when) |expr_src| {
            if (dsl.axis.parseString(self.arena, expr_src)) |expr| {
                try self.recordAxisExpr(expr, rel_path, null);
            } else |_| {
                // A malformed head expression is the apply-time run's problem
                // to report; discovery keeps the raw text and contributes no
                // axis role from it.
            }
        }

        var needs: ?[]const []const u8 = null;
        var needs_unparseable = false;
        if (head.needs) |raw| {
            const parsed = try parseNeeds(self.arena, raw);
            if (parsed.invalid) |bad| {
                try self.diagnostics.append(self.arena, .{ .needs_name = .{
                    .path = rel_path,
                    .name = bad,
                    .line = head.needs_line,
                } });
                needs_unparseable = true;
            } else {
                needs = parsed.names;
                for (parsed.names) |n| try self.registerNeedsName(n);
            }
        }

        try self.scripts.append(self.arena, .{
            .path = rel_path,
            .when_head = head.when,
            .scanned_tokens = try scanMoxFactTokens(self.arena, content),
            .needs = needs,
            .needs_unparseable = needs_unparseable,
        });
    }

    // -- final assembly -----------------------------------------------------

    fn finalize(self: *Discoverer) !Discovery {
        var dims_out: std.ArrayList(Dimension) = .empty;

        // Computed once over every discovered dimension name (not per-name):
        // collision detection is corpus-wide, mirroring `buildScriptEnv`'s own
        // two-pass tally over its whole fact list.
        var all_names: std.ArrayList([]const u8) = .empty;
        var name_it = self.dims.keyIterator();
        while (name_it.next()) |k| try all_names.append(self.arena, k.*);
        const projected = try source.fact_env.project(self.arena, try all_names.toOwnedSlice(self.arena));

        const resolved_defaults = try self.resolveDeclaredDefaults();

        var it = self.dims.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const dw = entry.value_ptr;
            const declared: []const []const u8 = if (resolved_defaults.get(name)) |v| blk: {
                const one = try self.arena.alloc([]const u8, 1);
                one[0] = v;
                break :blk one;
            } else &.{};
            try dims_out.append(self.arena, .{
                .name = name,
                .roles = dw.roles,
                .observed_values = try sortedKeys(self.arena, &dw.observed_values),
                .capture_defaults = try sortedKeys(self.arena, &dw.capture_defaults),
                .declared_defaults = declared,
                .asking_condition = try computeAskingCondition(self.arena, dw),
                .provenance = .{
                    .source_count = dw.sources.count(),
                    .needing_scripts = try self.needingScripts(name, projected),
                },
            });
        }
        const dims_slice = try dims_out.toOwnedSlice(self.arena);
        std.mem.sort(Dimension, dims_slice, {}, struct {
            fn lessThan(_: void, a: Dimension, b: Dimension) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        return .{
            .dimensions = dims_slice,
            .scripts = try self.scripts.toOwnedSlice(self.arena),
            .diagnostics = try self.diagnostics.toOwnedSlice(self.arena),
            .default_diagnostics = try self.default_diagnostics.toOwnedSlice(self.arena),
        };
    }

    /// Group every collected `# mox: default` occurrence by name and resolve
    /// each group to the single value every occurrence in it agrees on.
    /// Appends a `.conflict` diagnostic (naming the first two disagreeing
    /// sites) for a name with more than one distinct declared value -- no
    /// value is resolved for it, rather than an arbitrary pick -- and a
    /// `.unclaimed` diagnostic for a name that resolves cleanly but names no
    /// dimension any other source in the repo consumes (a default alone
    /// consumes nothing -- see the `.unclaimed` doc comment above). Same-
    /// value duplicates across files
    /// collapse silently: they are not an anomaly. A reserved name never
    /// reaches this grouping at all -- `recordDeclaredDefault` already
    /// diverted it straight to `self.default_diagnostics` at scan time.
    fn resolveDeclaredDefaults(self: *Discoverer) !std.StringHashMap([]const u8) {
        var groups = std.StringHashMap(std.ArrayList(RawDefault)).init(self.arena);
        for (self.declared_defaults.items) |raw| {
            const gop = try groups.getOrPut(raw.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, raw);
        }

        var resolved = std.StringHashMap([]const u8).init(self.arena);
        var it = groups.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const occurrences = entry.value_ptr.items;

            // Distinct values, in first-occurrence order.
            var distinct: std.ArrayList(RawDefault) = .empty;
            outer: for (occurrences) |occ| {
                for (distinct.items) |d| {
                    if (std.mem.eql(u8, d.value, occ.value)) continue :outer;
                }
                try distinct.append(self.arena, occ);
            }

            if (distinct.items.len > 1) {
                try self.default_diagnostics.append(self.arena, .{ .conflict = .{
                    .name = name,
                    .first_source = distinct.items[0].source,
                    .first_value = distinct.items[0].value,
                    .second_source = distinct.items[1].source,
                    .second_value = distinct.items[1].value,
                } });
                continue;
            }

            const value = distinct.items[0].value;
            if (self.dims.contains(name)) {
                try resolved.put(name, value);
            } else {
                try self.default_diagnostics.append(self.arena, .{ .unclaimed = .{
                    .name = name,
                    .source = occurrences[0].source,
                } });
            }
        }
        return resolved;
    }

    /// Every script that effectively consumes `dim_name`: via `# mox: needs`
    /// when the script declares one (direct name match, unaffected by
    /// `projected`), else via a `MOX_FACT_<NAME>` token found in its text --
    /// but only when `dim_name` itself projects onto a distinct token in
    /// `projected`. A name `buildScriptEnv` would skip (non-ASCII, or
    /// colliding with another dimension's projection) never actually reaches a
    /// script's environment, so a scanned-token match on it would link a
    /// script to a fact that is never really there. Sorted, deduped by
    /// construction (one entry per script).
    fn needingScripts(self: *Discoverer, dim_name: []const u8, projected: std.StringHashMap([]const u8)) ![]const []const u8 {
        const token = projected.get(dim_name);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.scripts.items) |s| {
            const consumes = if (s.needs) |names| blk: {
                for (names) |n| {
                    if (std.mem.eql(u8, n, dim_name)) break :blk true;
                }
                break :blk false;
            } else blk: {
                const tok = token orelse break :blk false;
                for (s.scanned_tokens) |t| {
                    if (std.mem.eql(u8, t, tok)) break :blk true;
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

/// True when `name` parses as an axis tuple (`os=linux`, `os=linux+profile=work`),
/// mirroring `apply.run_scripts.axisDirMatches`'s tuple-name validation --
/// discovery has no machine bindings to match against, so it validates shape
/// only, the same test a script-tuple dir must pass to be gated at all.
fn isAxisTupleDirName(arena: std.mem.Allocator, name: []const u8) bool {
    _ = source.tuple.parseFilename(arena, name) catch return false;
    return true;
}

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

/// `ctx` with `sibling` conjoined -- `recordAxisExpr`'s conjunction-sibling
/// rule: when recording one side of an `and_`, the OTHER side becomes an
/// extra required condition for every atom the first side records.
fn combineAndSibling(arena: std.mem.Allocator, ctx: ?*const AxisExpr, sibling: *const AxisExpr) !?*const AxisExpr {
    const c = ctx orelse return sibling;
    const node = try arena.create(AxisExpr);
    node.* = .{ .and_ = .{ .left = c, .right = sibling } };
    return node;
}

/// `stack` with `expr` appended (a fresh copy; `stack` itself is untouched).
fn appendStack(arena: std.mem.Allocator, stack: []const *const AxisExpr, expr: *const AxisExpr) ![]const *const AxisExpr {
    const out = try arena.alloc(*const AxisExpr, stack.len + 1);
    @memcpy(out[0..stack.len], stack);
    out[stack.len] = expr;
    return out;
}

/// `stack` unchanged when `maybe_expr` is null (an ungated directive
/// position), else `stack` with it appended.
fn appendIf(arena: std.mem.Allocator, stack: []const *const AxisExpr, maybe_expr: ?*const AxisExpr) ![]const *const AxisExpr {
    const expr = maybe_expr orelse return stack;
    return appendStack(arena, stack, expr);
}

/// `stack` with `not expr` appended, for a directive's false-branch body.
fn appendNot(arena: std.mem.Allocator, stack: []const *const AxisExpr, expr: *const AxisExpr) ![]const *const AxisExpr {
    const node = try arena.create(AxisExpr);
    node.* = .{ .not = expr };
    return appendStack(arena, stack, node);
}

/// `list` with `item` appended (a fresh copy; `list` itself is untouched).
fn appendStr(arena: std.mem.Allocator, list: []const []const u8, item: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = item;
    return out;
}

/// Null the moment any single occurrence (across every role: value-compared,
/// presence, captured) is itself unconditioned, or when the dimension somehow
/// has no occurrence at all. Otherwise the OR of every occurrence's
/// condition.
fn computeAskingCondition(arena: std.mem.Allocator, dw: *const DimWork) !?*const AxisExpr {
    if (dw.occurrence_conditions.items.len == 0) return null;
    var combined: ?*const AxisExpr = null;
    for (dw.occurrence_conditions.items) |maybe_cond| {
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
    /// 1-indexed line `needs` was found on, for `Diagnostic.needs_name`.
    /// Meaningless when `needs` is null.
    needs_line: u32 = 0,
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
                result.needs_line = @intCast(scanned);
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

const NeedsParse = struct {
    names: []const []const u8,
    /// The first token that failed the fact-name charset, or null when every
    /// token parsed cleanly. `names` holds whatever parsed before it, but the
    /// caller drops that partial list rather than trust a guessed contract.
    invalid: ?[]const u8 = null,
};

/// Parse a `# mox: needs` line's argument into whitespace-separated names.
/// An empty (or all-whitespace) argument is a valid explicit-empty list.
fn parseNeeds(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!NeedsParse {
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |tok| {
        if (!source.tuple.isValidAxisName(tok)) {
            return .{ .names = try names.toOwnedSlice(arena), .invalid = try arena.dupe(u8, tok) };
        }
        try names.append(arena, try arena.dupe(u8, tok));
    }
    return .{ .names = try names.toOwnedSlice(arena) };
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

// -- occurrence conditions apply to every role (value-compared, presence), --
// -- not only captures; conjunction siblings condition each other -----------

test "discover: a top-level solo eq atom is unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when use_1password_ssh_agent=true\nx = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "use_1password_ssh_agent").?;
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a conjunction-sibling presence occurrence is conditioned on the other conjunct" {
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
        "# mox: when profile=work and signing_work_key\nx = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "signing_work_key").?;
    try std.testing.expect(dim.roles.presence);
    const cond = dim.asking_condition.?;

    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
}

test "discover: both sides of a top-level `or` are unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when a_fact or b_fact\nx = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "a_fact").?.asking_condition == null);
    try std.testing.expect(findDim(d, "b_fact").?.asking_condition == null);
}

test "discover: an or-branch nested in an and inherits the and's other conjunct, not each other" {
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
        "# mox: when profile=work and (a_fact or b_fact)\nx = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    for ([_][]const u8{ "a_fact", "b_fact" }) |name| {
        const dim = findDim(d, name).?;
        const cond = dim.asking_condition.?;
        var bindings = std.StringHashMap([]const u8).init(a);
        var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
        try bindings.put("profile", "personal");
        try std.testing.expect(!dsl.axis.evaluate(cond, &r));
        try bindings.put("profile", "work");
        try std.testing.expect(dsl.axis.evaluate(cond, &r));
    }
}

test "discover: an occurrence nested inside another directive's own gate inherits it (value-compared, not just captured)" {
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
        "# mox: when profile=work\n# mox: when holt_backend=gdrive\nx = 1\n# mox: end\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expect(dim.roles.value_compared);
    const cond = dim.asking_condition.?;

    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
}

test "discover: a fact conditioned here but ALSO used unguarded elsewhere yields a null asking_condition" {
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
        "# mox: when profile=work and signing_work_key\nx = 1\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when signing_work_key\ny = 1\n# mox: end\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "signing_work_key").?.asking_condition == null);
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

test "discover: a malformed `# mox: needs` name is a loud diagnostic, not a fatal error -- scanning continues" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/bad.sh", "#!/bin/sh\n# mox: needs Not-Valid\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    try std.testing.expectEqual(@as(usize, 1), d.diagnostics.len);
    const diag = d.diagnostics[0].needs_name;
    try std.testing.expectEqualStrings("scripts/pre/bad.sh", diag.path);
    try std.testing.expectEqualStrings("Not-Valid", diag.name);
    try std.testing.expectEqual(@as(u32, 2), diag.line);

    try std.testing.expectEqual(@as(usize, 1), d.scripts.len);
    try std.testing.expect(d.scripts[0].needs == null);
    try std.testing.expect(d.scripts[0].needs_unparseable);
}

test "discover: a `# mox: needs` name with no other occurrence anywhere registers a scripts-only dimension, unconditioned and free-form" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/00-steam.sh", "#!/bin/sh\n# mox: needs steam_library\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "steam_library").?;
    try std.testing.expect(dim.asking_condition == null);
    try std.testing.expectEqual(@as(usize, 0), dim.observed_values.len);
    try std.testing.expect(!dim.roles.value_compared);
    try std.testing.expect(!dim.roles.captured);
    try std.testing.expect(!dim.roles.presence);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-steam.sh", dim.provenance.needing_scripts[0]);
}

test "discover: a `# mox: needs` name that is already a gated dimension elsewhere keeps its original condition, not flipped unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `onepassword_account` is captured only nested inside `when
    // profile=work`, so its own occurrence is genuinely conditioned (unlike
    // a bare top-level `when profile=work` gate, whose own comparison is
    // always unconditioned by design).
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when profile=work\nop = <machine.onepassword_account>\n# mox: end\n");
    try writeFile(io, tmp.dir, "scripts/pre/00-op.sh", "#!/bin/sh\n# mox: needs onepassword_account\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "onepassword_account").?;
    // Still conditioned by the src/ gate: a needs reference alone must not
    // silently widen an existing dimension's asking condition to null.
    try std.testing.expect(dim.asking_condition != null);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-op.sh", dim.provenance.needing_scripts[0]);
}

test "discover: a `# mox: needs` name excluded by category (built-in) registers no dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/00-os.sh", "#!/bin/sh\n# mox: needs os\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "os") == null);
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

test "discover: a script two levels deep under a non-tuple directory is not scanned at all" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "lib" is not an axis-tuple name (no `=`), so a script inside it must never
    // be scanned -- not even to notice its malformed `# mox: needs`, which
    // would otherwise fail the whole discovery loudly.
    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/lib/helper.sh",
        "#!/bin/sh\n# mox: needs Bad-Name\necho \"$MOX_FACT_X\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 0), d.scripts.len);
}

test "discover: the same malformed script still registers (fails loud) at top level" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/00-bad.sh",
        "#!/bin/sh\n# mox: needs Bad-Name\necho \"$MOX_FACT_X\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-bad.sh", d.diagnostics[0].needs_name.path);
}

test "discover: the same malformed script still registers (fails loud) one level inside a matching axis dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/os=linux/util.sh",
        "#!/bin/sh\n# mox: needs Bad-Name\necho \"$MOX_FACT_X\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/os=linux/util.sh", d.diagnostics[0].needs_name.path);
}

test "discover: a well-formed script one level inside an axis dir is scanned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/os=linux/util.sh",
        "#!/bin/sh\necho \"$MOX_FACT_UTIL_DIM\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/os=linux/util.sh", d.scripts[0].path);
}

test "discover: a directory whose name is not an axis tuple is never descended into" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/helpers/util.sh", "#!/bin/sh\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 0), d.scripts.len);
}

test "discover: two dimension names that sanitize to the same MOX_FACT_ token are not linked via a scanned token" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "Foo-Bar" and "foo_bar" both sanitize to MOX_FACT_FOO_BAR: buildScriptEnv
    // would skip BOTH (a collision, not a pick), so a scanned-token match must
    // not link either to the script.
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when Foo-Bar=x\na = 1\n# mox: end\n" ++
            "# mox: when foo_bar=y\nb = 1\n# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/00-both.sh",
        "#!/bin/sh\necho \"$MOX_FACT_FOO_BAR\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const foo_bar = findDim(d, "Foo-Bar").?;
    try std.testing.expectEqual(@as(usize, 0), foo_bar.provenance.needing_scripts.len);
    const foo_bar2 = findDim(d, "foo_bar").?;
    try std.testing.expectEqual(@as(usize, 0), foo_bar2.provenance.needing_scripts.len);
}

test "discover: an explicit `# mox: needs` link is unaffected by a token collision elsewhere" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when Foo-Bar=x\na = 1\n# mox: end\n" ++
            "# mox: when foo_bar=y\nb = 1\n# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/00-explicit.sh",
        "#!/bin/sh\n# mox: needs foo_bar\necho hi\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const foo_bar2 = findDim(d, "foo_bar").?;
    try std.testing.expectEqual(@as(usize, 1), foo_bar2.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-explicit.sh", foo_bar2.provenance.needing_scripts[0]);
}

test "discover: a capture field outside the fact-name charset is not a dimension and is reported loudly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "x = <machine.Bad-Name>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "Bad-Name") == null);
    try std.testing.expectEqual(@as(usize, 1), d.diagnostics.len);
    const diag = d.diagnostics[0].capture_name;
    try std.testing.expectEqualStrings("src/.zshrc", diag.path);
    try std.testing.expectEqualStrings("Bad-Name", diag.name);
}

// -- capture positions beyond a `when_gate` body -----------------------------

test "discover: an append body's capture is unconditioned (always emitted)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: append \"frag.sh\" when profile=work\n" ++
            "x = <machine.append_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "append_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a prepend body's capture is unconditioned (always emitted)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: prepend \"frag.sh\" when profile=work\n" ++
            "x = <machine.prepend_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "prepend_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a gate-false replace literal body's capture is conditioned on `not <gate>`" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: replace \"frag.sh\" when profile=work\n" ++
            "x = <machine.replace_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "replace_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;

    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
}

test "discover: a remove body's capture is conditioned on `not <gate>`" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: remove when profile=work\n" ++
            "x = <machine.remove_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "remove_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;

    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
}

test "discover: a `replace from` fallback body's capture is unconditioned (no fragment matched is not axis-expressible)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: replace from \"variant\"\n" ++
            "x = <machine.fromfallback_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "fromfallback_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a top-level `from` fallback body's capture is unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: from \"variant\"\n" ++
            "x = <machine.plainfrom_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "plainfrom_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a for-loop body's capture is unconditioned (per-row emission is not axis-expressible)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\"\n" ++
            "# x <machine.for_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "for_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a Cat B region fragment's own capture is unconditioned (tuple matching contributes nothing)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/kind.lua", "local M = {}\nreturn M\n");
    try writeFile(io, tmp.dir, "src/kind.lua.d/profile/work.lua", "M.kind = \"<machine.region_frag_dim>\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "region_frag_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: an include-target fragment's capture gets the include's own gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: include \"frag.sh\" when profile=work\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "y = <machine.include_dim>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "include_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;

    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
}

test "discover: an ungated include-target fragment's capture is unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: include \"frag.sh\"\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "y = <machine.include_ungated_dim>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "include_ungated_dim").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: an append fragment target's capture gets the append's own gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: append \"frag.sh\" when profile=work\n" ++
            "literal\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "y = <machine.append_frag_dim>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "append_frag_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
}

test "discover: a prepend fragment target's capture gets the prepend's own gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: prepend \"frag.sh\" when profile=work\n" ++
            "literal\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "y = <machine.prepend_frag_dim>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "prepend_frag_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
}

test "discover: a gate-true replace fragment target's capture gets the replace's own gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: replace \"frag.sh\" when profile=work\n" ++
            "literal\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "y = <machine.replace_frag_dim>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "replace_frag_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
}

// -- axis roles at full depth -------------------------------------------------

test "discover: an axis compared only in a `when` nested inside a for body is still value-compared" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\"\n" ++
            "# mox: when nested_axis=val\n" ++
            "# x 1\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "nested_axis").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), dim.observed_values.len);
    try std.testing.expectEqualStrings("val", dim.observed_values[0]);
}

test "discover: a dotted row-field reference in a nested for-body `when` is not an axis" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\"\n" ++
            "# mox: when entry.shells has \"zsh\"\n" ++
            "# x 1\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "entry") == null);
    try std.testing.expect(findDim(d, "shells") == null);
}

test "discover: a bare ref matching the enclosing loop variable's own name is not a phantom axis" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\"\n" ++
            "# mox: when entry\n" ++
            "# x 1\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "entry") == null);
}

test "discover: a `for` loop's own `when` clause nested inside a when-gate is still value-compared" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when profile=work\n" ++
            "# mox: for entry in \"data/tools.toml\" when nested_for_axis=val\n" ++
            "# x 1\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "nested_for_axis").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqualStrings("val", dim.observed_values[0]);
}

test "discover: a for loop's own `where` referencing its own loop variable is not a phantom axis" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `where entry` is a bare, undotted reference to the loop's OWN
    // variable: compose evaluates it with the loop's own frame already
    // bound (composeGenerator/evalRow prepend it before evalRow runs), so
    // it is that row's own presence check, not a machine axis.
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\" where entry\n# x 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "entry") == null);
}

test "discover: a for loop's own `where` referencing a genuine machine fact is still recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: for entry in \"data/tools.toml\" where signing_key\n# x 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "signing_key").?;
    try std.testing.expect(dim.roles.presence);
}

// -- declared defaults (`# mox: default`) ------------------------------------

test "discover: a `default` directive records a declared default on an already-real dimension" {
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
        "# mox: default holt_backend=\"icloud\"\n" ++
            "# mox: when holt_backend=gdrive\naccount = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), dim.declared_defaults.len);
    try std.testing.expectEqualStrings("icloud", dim.declared_defaults[0]);
    try std.testing.expectEqual(@as(usize, 0), d.default_diagnostics.len);
}

test "discover: a `default` directive nested inside an unrelated when-gate is still recorded, unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The default line sits inside a `profile=work` gate that has nothing to
    // do with `holt_backend`; a declared default is a repo-level statement,
    // so its own location's gates are irrelevant -- it must be recorded the
    // same as if it sat at the top level.
    try writeFile(
        io,
        tmp.dir,
        "src/.config/holt/config.toml",
        "# mox: when profile=work\n" ++
            "# mox: default holt_backend=\"icloud\"\n" ++
            "# mox: end\n" ++
            "# mox: when holt_backend=gdrive\naccount = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "holt_backend").?;
    try std.testing.expectEqual(@as(usize, 1), dim.declared_defaults.len);
    try std.testing.expectEqualStrings("icloud", dim.declared_defaults[0]);
}

test "discover: conflicting declared defaults for one name is a diagnostic naming both sites, no value resolved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/a.zshrc", "# mox: default conflict_dim=\"first\"\n");
    try writeFile(io, tmp.dir, "src/b.zshrc", "# mox: default conflict_dim=\"second\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.default_diagnostics.len);
    const diag = d.default_diagnostics[0];
    try std.testing.expect(diag == .conflict);
    try std.testing.expectEqualStrings("conflict_dim", diag.conflict.name);
    try std.testing.expectEqualStrings("src/a.zshrc", diag.conflict.first_source);
    try std.testing.expectEqualStrings("first", diag.conflict.first_value);
    try std.testing.expectEqualStrings("src/b.zshrc", diag.conflict.second_source);
    try std.testing.expectEqualStrings("second", diag.conflict.second_value);
}

test "discover: the same declared default value from two files dedupes silently" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/a.zshrc",
        "# mox: default dedupe_dim=\"same\"\n# mox: when dedupe_dim=x\ny = 1\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/b.zshrc", "# mox: default dedupe_dim=\"same\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 0), d.default_diagnostics.len);
    const dim = findDim(d, "dedupe_dim").?;
    try std.testing.expectEqual(@as(usize, 1), dim.declared_defaults.len);
    try std.testing.expectEqualStrings("same", dim.declared_defaults[0]);
}

test "discover: a declared default for a fact no source consumes is an unclaimed diagnostic, no dimension created" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/a.zshrc", "# mox: default unclaimed_dim=\"x\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "unclaimed_dim") == null);
    try std.testing.expectEqual(@as(usize, 1), d.default_diagnostics.len);
    const diag = d.default_diagnostics[0];
    try std.testing.expect(diag == .unclaimed);
    try std.testing.expectEqualStrings("unclaimed_dim", diag.unclaimed.name);
    try std.testing.expectEqualStrings("src/a.zshrc", diag.unclaimed.source);
}

test "discover: a declared default accepts a quoted UTF-8 value" {
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
        // "Tokyo" in kanji, as raw UTF-8 bytes.
        "# mox: default locale=\"\xe6\x9d\xb1\xe4\xba\xac\"\n" ++
            "# mox: when locale=tokyo\nx = 1\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "locale").?;
    try std.testing.expectEqual(@as(usize, 1), dim.declared_defaults.len);
    try std.testing.expectEqualStrings("\xe6\x9d\xb1\xe4\xba\xac", dim.declared_defaults[0]);
}

test "discover: a declared default naming a built-in is a loud diagnostic, not a fatal error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/a.zshrc", "# mox: default os=\"linux\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "os") == null);
    try std.testing.expectEqual(@as(usize, 1), d.default_diagnostics.len);
    const diag = d.default_diagnostics[0].reserved;
    try std.testing.expectEqualStrings("os", diag.name);
    try std.testing.expectEqualStrings("src/a.zshrc", diag.source);
}

test "discover: a declared default naming an open probe axis is a loud diagnostic, not a fatal error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/a.zshrc", "# mox: default tool=\"fd\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.default_diagnostics.len);
    try std.testing.expectEqualStrings("tool", d.default_diagnostics[0].reserved.name);
}

test "discover: a declared default naming a data/facts.toml-derived name is a loud diagnostic, not a fatal error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "data/facts.toml", "[[facts]]\nname = \"brew_prefix\"\ncandidates = [\"/opt/homebrew\"]\n");
    try writeFile(io, tmp.dir, "src/a.zshrc", "# mox: default brew_prefix=\"/opt/homebrew\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), d.default_diagnostics.len);
    try std.testing.expectEqualStrings("brew_prefix", d.default_diagnostics[0].reserved.name);
}

test "discover: corpus-shaped fixture with a declared default added -- every other dimension is unchanged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same fixture as "discover: integration -- gdrive_account gated, ..."
    // (the corpus's own shape: a gated capture, a profile=work-gated pair,
    // and a captured+compared `profile`), with one addition: the holt config
    // declares its lost gated-only default back in-source, exactly the edit
    // the real dotfiles fold makes after this ships.
    try writeFile(
        io,
        tmp.dir,
        "src/.config/holt/config.toml",
        "# mox: default holt_backend=\"icloud\"\n" ++
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

    // Every assertion from the corpus-shaped integration test, unchanged.
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

    const profile = findDim(d, "profile").?;
    try std.testing.expect(profile.roles.value_compared);
    try std.testing.expect(profile.roles.captured);
    try std.testing.expectEqual(@as(usize, 1), profile.observed_values.len);
    try std.testing.expectEqualStrings("work", profile.observed_values[0]);
    try std.testing.expectEqual(@as(usize, 1), profile.capture_defaults.len);
    try std.testing.expectEqualStrings("personal", profile.capture_defaults[0]);
    try std.testing.expect(profile.asking_condition == null);
    try std.testing.expectEqual(@as(usize, 0), profile.declared_defaults.len);

    // The addition: holt_backend also carries the declared default, cleanly
    // (one source, one value, no diagnostic).
    const holt_backend = findDim(d, "holt_backend").?;
    try std.testing.expectEqual(@as(usize, 1), holt_backend.declared_defaults.len);
    try std.testing.expectEqualStrings("icloud", holt_backend.declared_defaults[0]);
    try std.testing.expectEqual(@as(usize, 0), d.default_diagnostics.len);
}

// -- recursion is bounded (defensive; no fixture requires this depth) -------

test "discover: pathologically deep nested when-gates do not hang or overflow the stack" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var content: std.ArrayList(u8) = .empty;
    const depth = 500;
    var i: usize = 0;
    while (i < depth) : (i += 1) try content.appendSlice(a, "# mox: when deep_axis=val\n");
    try content.appendSlice(a, "x = 1\n");
    i = 0;
    while (i < depth) : (i += 1) try content.appendSlice(a, "# mox: end\n");

    try writeFile(io, tmp.dir, "src/.zshrc", content.items);

    const repo = try tmpAbsPath(a, &tmp, "");
    // Must return (not hang, not crash) regardless of the exact result.
    _ = try discover(a, io, repo);
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
    try std.testing.expect(d.tree_error == null);
}

test "discover: a structurally invalid source tree sets tree_error and still degrades to empty dimension content" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/path=brew", "[gpg]\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(error.ReservedAxisName, d.tree_error.?);
    // The invalid tree degrades to "nothing found" for dimension content --
    // apply's own richer walkDiag call owns the per-site message for this
    // file, not discovery.
    try std.testing.expectEqual(@as(usize, 0), d.dimensions.len);
}
