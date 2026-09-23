//! Config-space discovery: a dedicated pre-interview pass that scans a repo's
//! `src/` tree, `scripts/pre|post` trees, and the TOML data sources their
//! `for` loops read, for every custom fact ("dimension") the repo's sources
//! actually consume, instead of a hand-maintained schema file. Pure function
//! of (repo_dir, io, alloc): no state is written. Wired into `apply` (before
//! the interview) and `mox facts`.
//!
//! A dimension is discovered through three channels, at any nesting depth a
//! directive's body reaches (a `# mox: when` nested inside a `when`/`for`/
//! `append`/... body is honored by compose's own recursive emit, so this scan
//! follows it there too):
//!   - value-compared: `name=value` in a gate, region, whole-file gate, overlay
//!     filename tuple, scripts gate-directory tuple, generator gate, or script
//!     `# mox: when` head, with the
//!     observed literal value set (a `name = <var>.field` row predicate is
//!     value-compared with an EMPTY observed set; `bound <var>.field` names no
//!     axis and contributes nothing; a bare, undotted `present`/`has`/`eq`
//!     inside a for-loop row predicate is a machine-axis reference exactly
//!     when the row-expr grammar itself treats it as one -- its head names no
//!     enclosing loop frame -- and is recorded the same way).
//!   - captured: `<machine.NAME>` occurrences anywhere compose would actually
//!     emit them -- a managed file's base content (recursing into every
//!     nested `# mox: when`/`for` region), a directive's literal body, a
//!     generator `for`'s `into` path template, the fragment file an
//!     `include`/`append`/`prepend`/`replace`/`from` target or a Cat B
//!     region names, a Cat A `.d/` overlay's own content (Cat B never reads
//!     `file.overlays` and Cat C copies the winning layer out verbatim, so
//!     an overlay of either is text compose never expands), and the row
//!     values of the TOML data source a `for` reads (compose splices a row
//!     value into the loop body and expands the captures it carries) -- each
//!     with its `| default`.
//!   - presence-only: a bare `when NAME` gate.
//!
//! Every occurrence of every role -- value-compared, presence, or captured
//! alike -- carries an asking condition: the conjunction of enclosing
//! conditions that are both cleanly axis-expressible and required for
//! emission, AND its conjunction-sibling predicates within the same `and`
//! (its own atom excluded; a sibling under an `or` contributes nothing, an
//! atom there can be demanded alone). A negated-gate body contributes
//! `not <gate>`; an overlay's content contributes its filename tuple, each
//! candidate reading of it, which is the test `compose.catA.
//! collectMatchingLayers` itself makes before folding that layer in; a
//! script's `# mox: when` head, its declared `# mox: needs`, and -- when it
//! declares none -- each scanned `MOX_FACT_*` token naming a known dimension
//! contribute the tuple of the gate directory holding it, which is what
//! `apply.run_scripts` requires before running it at all. A
//! from-fallback body, a for-loop's per-row emission, and a Cat B region's
//! fragment pick contribute nothing -- over-asking is safe, under-asking is
//! not. A dimension's `asking_condition` is the OR of every occurrence's
//! condition, null the moment any single occurrence is itself unconditioned.
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
const capture = @import("../compose/capture.zig");
const compose = @import("../compose/root.zig");
const data = @import("../data/root.zig");
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
    /// Number of distinct source files (`src/` tree files, the data sources
    /// their loops read, and scripts) that reference this dimension via a
    /// value-compared, presence, or capture occurrence. A script's
    /// `# mox: needs`/`MOX_FACT_*` consumption is tracked separately in
    /// `needing_scripts`, not counted here.
    source_count: usize,
    /// Repo-relative paths of scripts that consume this dimension: via
    /// `# mox: needs` when present, else via a `MOX_FACT_<NAME>` token found
    /// in the script's text. Sorted, deduped.
    needing_scripts: []const []const u8,
};

/// Write `p` as a compact provenance summary, no surrounding punctuation or
/// trailing newline (`"3 sources, needs: scripts/pre/00-op.sh"`) -- the
/// shared text between the interview's per-prompt provenance line, `mox
/// status`'s unbound-facts section, and `mox facts --report`.
pub fn writeProvenance(out: *std.Io.Writer, p: Provenance) !void {
    try out.print("{d} source{s}", .{ p.source_count, if (p.source_count == 1) "" else "s" });
    if (p.needing_scripts.len > 0) {
        try out.writeAll(", needs:");
        for (p.needing_scripts) |s| try out.print(" {s}", .{s});
    }
}

pub const Dimension = struct {
    name: []const u8,
    roles: Roles,
    /// Observed literal values (gate/region/overlay/generator/script-when
    /// comparisons), sorted and deduped. Empty for a name only ever compared
    /// via a `name = <var>.field` row predicate, or only ever captured.
    observed_values: []const []const u8,
    /// Every distinct `| default "..."` value observed on a capture of this
    /// name alone, sorted and deduped. A fallback chain's default contributes
    /// nothing: it rescues the exhausted chain, not the machine member.
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
    /// text, sorted and deduped. When no `# mox: needs` head replaces them
    /// these are the script's effective demands, so each one that names a
    /// known dimension widens that dimension's asking condition by `gate`.
    scanned_tokens: []const []const u8,
    /// The gate-directory tuple this script sits under (null at a stage's
    /// top level): the condition `apply.run_scripts` requires before running
    /// it at all, and so the condition every demand it makes is asked under.
    gate: ?*const AxisExpr = null,
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
    /// A `machine.NAME` capture reference -- alone or as one fallback-chain
    /// member -- whose NAME failed the fact-name charset (`[a-z][a-z0-9_]*`):
    /// recorded nowhere as a dimension.
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

    /// A `# mox: needs NAME` reference is an occurrence of `NAME` like any
    /// other: it registers the dimension when nothing else in the repo made
    /// it real -- free-form, no role -- and either way records its own
    /// asking condition, `condition` (the script's gate directory, or null
    /// at a stage's top level), which ORs with every other occurrence's.
    /// A name the source tree already conditioned is widened, not left
    /// alone: the script consumes the fact wherever the runner runs it, so
    /// an ungated script needing a name `src/` only uses behind a gate makes
    /// it unconditioned -- under-asking it would leave the script demanding,
    /// on every machine whose gate is closed, a fact no interview ever
    /// offers to bind. An excluded name
    /// (built-in, open axis, reserved, `data/facts.toml`-derived) registers
    /// nothing, same as `dimFor` everywhere else -- it already has its own
    /// resolution path, not an interview question.
    fn registerNeedsName(self: *Discoverer, name: []const u8, condition: ?*const AxisExpr) !void {
        const dw = (try self.dimFor(name)) orelse return;
        try dw.occurrence_conditions.append(self.arena, condition);
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
            .from, .secret, .default, .keep_empty => {},
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
    /// Record each pair of an overlay's, fragment's, or scripts-gate
    /// directory's filename tuple as a value comparison. A filename whose
    /// extension heuristic stripped a suffix carries a second, verbatim
    /// reading in `exact`; compose matches under either, so BOTH values are
    /// observed -- otherwise the interview offers a value that selects
    /// nothing and warns about the one that does.
    fn recordTuple(
        self: *Discoverer,
        tuple: source.tree.AxisTuple,
        exact: ?source.tree.AxisTuple,
        source_key: []const u8,
    ) !void {
        for (tuple.pairs, 0..) |p, i| {
            if (try self.dimFor(p.name)) |dw| {
                dw.roles.value_compared = true;
                try dw.observed_values.put(try self.arena.dupe(u8, p.value), {});
                if (source.tuple.exactValueAt(exact, i)) |v| {
                    try dw.observed_values.put(try self.arena.dupe(u8, v), {});
                }
                try dw.sources.put(source_key, {});
                try dw.occurrence_conditions.append(self.arena, null);
            }
        }
    }

    // -- capture + nested-directive traversal --------------------------------

    /// Recursion state threaded through a file's directive tree. `gate_stack`
    /// holds every enclosing condition that is both cleanly axis-expressible
    /// and required for emission, innermost last -- a capture's condition is
    /// their conjunction (over-asking is safe, under-asking is not: anything not
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
    /// region body) and scan its own content lines for `machine.` capture
    /// references at `nest.gate_stack`'s condition. Each directive is then
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
            try self.scanCaptures(line, condition, source_key);
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
                const stack = try appendIf(self.arena, nest.gate_stack, loop.when);
                // A generator's `into` template is expanded per row exactly
                // like its body, so a capture there is as real as one in it.
                if (loop.into) |into| try self.scanFlatText(into, stack, source_key);
                if (!isEnclosingFieldRef(loop.data_source, nest.loop_vars)) {
                    try self.scanLoopDataSource(nest.file, loop.data_source, stack);
                }
                const loop_vars = try appendStr(self.arena, nest.loop_vars, loop.variable);
                const inner: Nest = .{
                    .file = nest.file,
                    .marker = nest.marker,
                    .gate_stack = stack,
                    .loop_vars = loop_vars,
                    .in_for = true,
                    .depth = nest.depth + 1,
                };
                try self.scanBody(loop.body_template, source_key, inner);
            },
            .completions, .secret, .default, .keep_empty => {},
        }
    }

    /// Scan flat text -- a directive's own literal body, or a fragment file's
    /// content, neither of which compose ever re-parses for directives -- for
    /// `machine.` capture references at `stack`'s condition.
    fn scanFlatText(self: *Discoverer, text: []const u8, stack: []const *const AxisExpr, source_key: []const u8) !void {
        const condition = try combineAnd(self.arena, stack);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try self.scanCaptures(line, condition, source_key);
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

    /// Read the TOML data source a `for` names and scan the row values that
    /// loop will interpolate, at `stack`'s condition -- the same condition the
    /// loop's own body and `into` template already carry, since a row value is
    /// spliced INTO that body and expanded there (`compose.interp`'s one-level
    /// nested expansion). Only a string field and a string array's elements
    /// can carry a capture: an int or bool has no text, a nested table is
    /// dropped by the same projection compose loads rows through, and a key is
    /// looked up rather than emitted.
    ///
    /// The file is READ ONLY, through that same projection, so nothing another
    /// reader of the file sees changes. Any failure to resolve, read, or parse
    /// it is skipped silently: a broken data source is apply's problem to
    /// report with the offending path, exactly as an unreadable fragment
    /// already is here.
    fn scanLoopDataSource(
        self: *Discoverer,
        file: source.tree.ManagedFile,
        data_source: []const u8,
        stack: []const *const AxisExpr,
    ) !void {
        const abs = (file.dataSourcePath(self.arena, self.io, data_source) catch return) orelse return;
        const content = Io.Dir.cwd().readFileAlloc(self.io, abs, self.arena, .limited(max_file_bytes)) catch return;
        const rows = (data.toml.parse(self.arena, content) catch return)
            .get(data.source.arrayName(data_source)) orelse return;

        // The data file is its own source: a capture is written there, not in
        // the file whose loop reads it, and that is where `mox facts --report`
        // must send a reader looking for it.
        const source_key = try self.dataSourceKey(file, data_source);
        const condition = try combineAnd(self.arena, stack);
        for (rows) |row| {
            var it = row.valueIterator();
            while (it.next()) |v| switch (v.*) {
                .string => |s| try self.scanCaptures(s, condition, source_key),
                .array_of_strings => |arr| for (arr) |elem| {
                    try self.scanCaptures(elem, condition, source_key);
                },
                .int, .bool => {},
            };
        }
    }

    /// True when a `for`'s source names an enclosing loop variable's field
    /// (`for url in id.match_urls`) rather than a file, the same test
    /// `compose.catB.loopFieldRef` makes before it falls back to a path. Such
    /// a loop reads no file of its own: its elements are the enclosing row's
    /// array field, already scanned with that row.
    fn isEnclosingFieldRef(data_source: []const u8, loop_vars: []const []const u8) bool {
        if (std.mem.indexOfScalar(u8, data_source, '/') != null) return false;
        const dot = std.mem.indexOfScalar(u8, data_source, '.') orelse return false;
        for (loop_vars) |v| {
            if (std.mem.eql(u8, v, data_source[0..dot])) return true;
        }
        return false;
    }

    /// The repo-relative key naming a loop's data source, matching the form
    /// `dataSourcePath` resolved it from: a `/`-bearing source is already one,
    /// a bare name sits in the reading file's own `<base>.d/`.
    fn dataSourceKey(
        self: *Discoverer,
        file: source.tree.ManagedFile,
        data_source: []const u8,
    ) ![]const u8 {
        if (std.mem.indexOfScalar(u8, data_source, '/') != null) return data_source;
        return std.fmt.allocPrint(self.arena, "{s}.d/{s}", .{ file.source_base_path, data_source });
    }

    /// Record every `machine.NAME` reference `text` carries, at `condition`.
    /// `text` is one interpolation unit -- a source line, or a whole data-row
    /// value, each of which `compose.interp` expands as a unit. The walk
    /// mirrors that interpolator's own, over the same shared capture grammar:
    /// a `machine.` reference counts wherever a chain member may stand, since
    /// `resolveChain` evaluates EVERY member and lets the first non-empty one
    /// win -- which one that is depends on values discovery cannot know, so
    /// all of them are asked.
    fn scanCaptures(self: *Discoverer, text: []const u8, condition: ?*const AxisExpr, source_key: []const u8) !void {
        // Every reference this can record spells `machine.` literally, so a
        // text without it holds none, and is not worth walking capture by
        // capture.
        if (std.mem.indexOf(u8, text, "machine.") == null) return;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
            const close = capture.closeIndex(text, open) orelse {
                i = open + 1;
                continue;
            };
            const inner = text[open + 1 .. close];
            // A `<secret:URI>` body is verbatim payload to the resolver, never
            // a chain and never interpolated further.
            if (std.mem.startsWith(u8, inner, "secret:")) {
                i = close + 1;
                continue;
            }

            const split = capture.splitDefault(inner);
            const chain = capture.isChain(split.field);
            var members = capture.members(split.field);
            while (members.next()) |member| {
                if (!std.mem.startsWith(u8, member, "machine.")) continue;
                // A chain's `| default` rescues the EXHAUSTED chain, not any
                // one member, so it is no member's own interview default.
                try self.recordCaptureMember(
                    member["machine.".len..],
                    if (chain) null else split.default,
                    condition,
                    source_key,
                );
            }

            // `compose.interp` consumes a capture whose body names a namespace
            // or holds a chain, and otherwise advances a single byte (a bare
            // name is a scope/record reference, or plain text). Advancing the
            // same way keeps a `<machine.X>` written behind a stray `<` as
            // discoverable as it is interpolable.
            i = if (chain or capture.hasNamespace(split.field)) close + 1 else open + 1;
        }
    }

    /// Fold one `machine.NAME` reference into its dimension: a name outside
    /// the fact-name charset becomes a diagnostic instead, and one excluded by
    /// category is dropped.
    fn recordCaptureMember(
        self: *Discoverer,
        field: []const u8,
        default_opt: ?[]const u8,
        condition: ?*const AxisExpr,
        source_key: []const u8,
    ) !void {
        if (field.len == 0) return;
        // Open axis: excluded by category, not by name list, but skipped
        // here up front since `tool_path.<name>` is not itself a single
        // dimension name `dimFor` would even parse sensibly.
        if (std.mem.startsWith(u8, field, "tool_path.")) return;

        if (!source.tuple.isValidAxisName(field)) {
            try self.diagnostics.append(self.arena, .{ .capture_name = .{
                .path = source_key,
                .name = try self.arena.dupe(u8, field),
            } });
            return;
        }

        const dw = (try self.dimFor(field)) orelse return;
        dw.roles.captured = true;
        try dw.sources.put(source_key, {});
        try dw.occurrence_conditions.append(self.arena, condition);
        if (default_opt) |def| try dw.capture_defaults.put(try self.arena.dupe(u8, def), {});
    }

    // -- per-file dispatch ------------------------------------------------

    /// Scan each axis-named `.d/` overlay's own content for captures, at the
    /// condition its filename already imposes. Only a Cat A file reaches the
    /// interpolator with an overlay's bytes in hand: Cat B never consults
    /// `file.overlays` at all, and Cat C copies the winning layer out
    /// verbatim, so a `<machine.NAME>` in either is text compose never
    /// expands and must not become a fact the interview asks for.
    ///
    /// Compose reads an overlay as flat text -- no head strip (`compose.catA.
    /// readBaseHead` returns an overlay seed verbatim) and no directive parse
    /// (`compose.catA.refuseRegionInLayers` refuses a content directive in any
    /// layer of an overlay-bearing file, matching or not) -- so this reads it
    /// the same way.
    fn scanOverlayContent(self: *Discoverer, file: source.tree.ManagedFile, source_key: []const u8) !void {
        if (file.overlays.len == 0) return;
        // An unreadable sample is compose's to report; there is nothing to
        // discover behind it.
        const cat = (compose.categoryOf(self.arena, self.io, file) catch return) orelse return;
        if (cat != .a) return;
        for (file.overlays) |ov| {
            const content = Io.Dir.cwd().readFileAlloc(self.io, ov.path, self.arena, .limited(max_file_bytes)) catch continue;
            // `compose.match.effectiveOverlayTuple` takes the verbatim-filename
            // reading when it holds and the extension-stripped one otherwise,
            // so the layer merges under either: one occurrence each, which the
            // dimension's asking condition ORs.
            try self.scanFlatText(content, try self.tupleStack(ov.tuple), source_key);
            if (ov.exact_tuple) |exact| {
                try self.scanFlatText(content, try self.tupleStack(exact), source_key);
            }
        }
    }

    /// `tuple` as a gate stack: one `axis=value` atom per pair, which
    /// `combineAnd` conjoins into exactly the test `compose.catA.
    /// collectMatchingLayers` makes before folding that layer in.
    fn tupleStack(self: *Discoverer, tuple: source.tree.AxisTuple) ![]const *const AxisExpr {
        const out = try self.arena.alloc(*const AxisExpr, tuple.pairs.len);
        for (tuple.pairs, out) |pair, *slot| {
            const node = try self.arena.create(AxisExpr);
            node.* = .{ .eq = .{ .axis = pair.name, .value = pair.value } };
            slot.* = node;
        }
        return out;
    }

    fn scanManagedFile(self: *Discoverer, file: source.tree.ManagedFile) !void {
        const source_key = file.source_base_path;

        for (file.overlays) |ov| try self.recordTuple(ov.tuple, ov.exact_tuple, source_key);
        try self.scanOverlayContent(file, source_key);
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
                try self.recordTuple(fr.tuple, fr.exact_tuple, source_key);
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
        const marker = dsl.comment.markerForFile(file.source_base_path, raw) orelse {
            // Mirrors compose's own null-marker passthrough (`compose.catB.
            // composeTrackedContent`): with no marker at all, no directive
            // can exist in this file either, but compose still interpolates
            // `<machine.X>` line by line -- scan the same, unconditioned.
            try self.scanFlatText(raw, &.{}, source_key);
            return;
        };
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
            if (source.junk.isJunk(e.name)) continue;
            switch (e.kind) {
                .directory => {
                    if (axisTupleDirName(self.arena, e.name)) |tuple| try self.scanGatedScriptsDir(abs, rel, tuple);
                },
                .file => try self.scanScriptFile(abs, rel, null),
                else => {},
            }
        }
    }

    /// The non-recursive second level `scanScriptsTree` descends into: every
    /// regular file directly inside a matching axis-tuple directory, no
    /// further subdirectories. `tuple` is that directory's gate, which
    /// `apply.run_scripts` requires before it runs anything inside -- so it
    /// is recorded as a value comparison in its own right (unconditioned,
    /// like any overlay filename's: the fact that opens the gate must be
    /// asked before anything behind it) and conditions every contribution the
    /// scripts inside make.
    fn scanGatedScriptsDir(
        self: *Discoverer,
        abs_dir: []const u8,
        rel_prefix: []const u8,
        tuple: source.tree.AxisTuple,
    ) !void {
        try self.recordTuple(tuple, null, rel_prefix);
        const gate = try combineAnd(self.arena, try self.tupleStack(tuple));
        // A gate directory that cannot be read is apply's to report, as a
        // failed script; there is nothing to discover in it.
        const entries = source.dirent.sortedPath(self.arena, self.io, abs_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return,
        };
        for (entries) |e| {
            if (e.kind != .file or source.junk.isJunk(e.name)) continue;
            const abs = try std.fs.path.join(self.arena, &.{ abs_dir, e.name });
            const rel = try source.path.joinKey(self.arena, &.{ rel_prefix, e.name });
            try self.scanScriptFile(abs, rel, gate);
        }
    }

    /// `gate` is the enclosing gate-directory tuple's condition (null at the
    /// stage's top level), which every contribution this script makes is
    /// conditioned on: `apply.run_scripts` runs it only where that tuple
    /// matches, and a `# mox: when` head of its own narrows it further rather
    /// than replacing it.
    fn scanScriptFile(self: *Discoverer, abs_path: []const u8, rel_path: []const u8, gate: ?*const AxisExpr) !void {
        const content = Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.arena, .limited(max_script_bytes)) catch return;

        const head = scanScriptHead(content);
        if (head.when) |expr_src| {
            if (dsl.axis.parseString(self.arena, expr_src)) |expr| {
                try self.recordAxisExpr(expr, rel_path, gate);
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
                for (parsed.names) |n| try self.registerNeedsName(n, gate);
            }
        }

        try self.scripts.append(self.arena, .{
            .path = rel_path,
            .when_head = head.when,
            .scanned_tokens = try scanMoxFactTokens(self.arena, content),
            .needs = needs,
            .needs_unparseable = needs_unparseable,
            .gate = gate,
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
        try self.widenByScannedTokens(projected);

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
    /// when the script declares one, else via a `MOX_FACT_<NAME>` token found
    /// in its text. Sorted, deduped by construction (one entry per script).
    fn needingScripts(self: *Discoverer, dim_name: []const u8, projected: std.StringHashMap([]const u8)) ![]const []const u8 {
        const token = projected.get(dim_name);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.scripts.items) |s| {
            if (consumesByNeeds(s, dim_name) or consumesByToken(s, token)) try out.append(self.arena, s.path);
        }
        const slice = try out.toOwnedSlice(self.arena);
        std.mem.sort([]const u8, slice, {}, lessThanStr);
        return slice;
    }

    /// Widen each dimension by the scripts that consume it through a scanned
    /// `MOX_FACT_*` token rather than a `# mox: needs` head. Such a token is
    /// a demand exactly as strong as a declared one: `apply.run_scripts.
    /// classifyToken` blocks the run on it, so under-asking it leaves the
    /// script demanding, wherever the runner reaches it, a fact no interview
    /// ever offered to bind. Each match appends the script's own gate as one
    /// more occurrence condition, the same widening `registerNeedsName` does.
    ///
    /// It never CREATES a dimension, unlike a declared need. A token is
    /// matched text, not a stated contract, and `fact_env.envName` is lossy
    /// (`MOX_FACT_A_B` names `a.b`, `a_b`, `A-B` alike), so a token matching
    /// no known fact has no name to register and must stay fail-closed at the
    /// runner, which blocks it there rather than inventing an interview
    /// question for a fact that may not exist at all.
    ///
    /// Runs before any asking condition is computed, and after `projected`,
    /// whose collision detection is corpus-wide and so needs every name first.
    fn widenByScannedTokens(self: *Discoverer, projected: std.StringHashMap([]const u8)) !void {
        var it = self.dims.iterator();
        while (it.next()) |entry| {
            const token = projected.get(entry.key_ptr.*);
            for (self.scripts.items) |s| {
                if (consumesByToken(s, token)) try entry.value_ptr.occurrence_conditions.append(self.arena, s.gate);
            }
        }
    }
};

/// True when `s` declares a `# mox: needs` list naming `dim_name`. Unaffected
/// by projection: a declared name is matched directly.
fn consumesByNeeds(s: ScriptRecord, dim_name: []const u8) bool {
    const names = s.needs orelse return false;
    for (names) |n| {
        if (std.mem.eql(u8, n, dim_name)) return true;
    }
    return false;
}

/// True when `s` declares no `# mox: needs` list -- so its token scan is its
/// effective consumption set -- and `token` is among the tokens scanned from
/// its text. `token` is the dimension's own projection, null when it has
/// none: a name `buildScriptEnv` would skip (non-ASCII, or colliding with
/// another dimension's projection) never actually reaches a script's
/// environment, so a scanned-token match on it would claim a fact that is
/// never really there.
fn consumesByToken(s: ScriptRecord, token: ?[]const u8) bool {
    if (s.needs != null) return false;
    const tok = token orelse return false;
    for (s.scanned_tokens) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

/// `name` parsed as an axis tuple (`os=linux`, `os=linux+profile=work`),
/// mirroring `apply.run_scripts.axisDirVerdict`'s own parse -- a directory
/// name carries no extension, so there is one reading, not two. Null when
/// `name` is not a tuple: discovery has no machine bindings to match against,
/// so this decides shape only, the same test a script-tuple dir must pass to
/// be gated at all.
fn axisTupleDirName(arena: std.mem.Allocator, name: []const u8) ?source.tree.AxisTuple {
    return source.tuple.parseFilenameVerbatim(arena, name) catch null;
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

/// `expr` flattened into its and-conjoined atoms: `a and b and c` -> `{a, b,
/// c}`; anything else (including a single `not`/`present`/`eq`/`or_`) is its
/// own one-element atom set.
fn atomsOf(arena: std.mem.Allocator, expr: *const AxisExpr) ![]const *const AxisExpr {
    return switch (expr.*) {
        .and_ => |a| blk: {
            const left = try atomsOf(arena, a.left);
            const right = try atomsOf(arena, a.right);
            const out = try arena.alloc(*const AxisExpr, left.len + right.len);
            @memcpy(out[0..left.len], left);
            @memcpy(out[left.len..], right);
            break :blk out;
        },
        else => blk: {
            const out = try arena.alloc(*const AxisExpr, 1);
            out[0] = expr;
            break :blk out;
        },
    };
}

/// True when every atom in `sub` (by `exprEqual`) also appears in `super`.
fn atomSetSubset(sub: []const *const AxisExpr, super: []const *const AxisExpr) bool {
    for (sub) |sub_atom| {
        var found = false;
        for (super) |super_atom| {
            if (dsl.ast.exprEqual(sub_atom, super_atom)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Flatten every top-level `or_` in `expr` (recursively) into `out`, so a
/// disjunct that is itself `X or Y` contributes `X` and `Y` as separate
/// leaves rather than one leaf that is itself an `or_`.
fn flattenOrLeaves(arena: std.mem.Allocator, out: *std.ArrayList(*const AxisExpr), expr: *const AxisExpr) !void {
    switch (expr.*) {
        .or_ => |o| {
            try flattenOrLeaves(arena, out, o.left);
            try flattenOrLeaves(arena, out, o.right);
        },
        else => try out.append(arena, expr),
    }
}

/// Sound (equivalence-preserving) simplification of an OR of conjunctions,
/// applied at construction so the STORED asking condition is clean -- this
/// is what eligibility re-evaluates on every interview wave, not just what a
/// report prints. Two provably-safe reductions only, no general boolean
/// minimization (no distribution, no negation reasoning -- `not X` is an
/// opaque atom):
///   - dedup: drop a later disjunct that is structurally identical
///     (`ast.exprEqual`) to an earlier surviving one.
///   - absorption: `A or (A and B) = A` -- treating each disjunct as the SET
///     of its and-conjoined atoms (flattened; a non-`and_` disjunct is its
///     own singleton set), drop any disjunct whose atom set is a STRICT
///     superset of another surviving disjunct's atom set.
/// `disjuncts` must be non-empty; a nested `or_` inside any one of them is
/// flattened into the disjunct list before dedup/absorption run.
fn simplifyOr(arena: std.mem.Allocator, disjuncts: []const *const AxisExpr) !*const AxisExpr {
    var flat: std.ArrayList(*const AxisExpr) = .empty;
    for (disjuncts) |d| try flattenOrLeaves(arena, &flat, d);

    var deduped: std.ArrayList(*const AxisExpr) = .empty;
    for (flat.items) |cand| {
        var dup = false;
        for (deduped.items) |kept| {
            if (dsl.ast.exprEqual(cand, kept)) {
                dup = true;
                break;
            }
        }
        if (!dup) try deduped.append(arena, cand);
    }

    const atom_sets = try arena.alloc([]const *const AxisExpr, deduped.items.len);
    for (deduped.items, 0..) |d, i| atom_sets[i] = try atomsOf(arena, d);

    var survivors: std.ArrayList(*const AxisExpr) = .empty;
    for (deduped.items, 0..) |d, i| {
        var absorbed = false;
        for (atom_sets, 0..) |other_atoms, j| {
            if (i == j) continue;
            if (atomSetSubset(other_atoms, atom_sets[i]) and !atomSetSubset(atom_sets[i], other_atoms)) {
                absorbed = true;
                break;
            }
        }
        if (!absorbed) try survivors.append(arena, d);
    }

    // Rebuild a right-leaning or-tree: A or (B or (C or D)).
    var idx = survivors.items.len - 1;
    var acc = survivors.items[idx];
    while (idx > 0) {
        idx -= 1;
        const node = try arena.create(AxisExpr);
        node.* = .{ .or_ = .{ .left = survivors.items[idx], .right = acc } };
        acc = node;
    }
    return acc;
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
    var conds: std.ArrayList(*const AxisExpr) = .empty;
    for (dw.occurrence_conditions.items) |maybe_cond| {
        const cond = maybe_cond orelse return null;
        try conds.append(arena, cond);
    }
    return try simplifyOr(arena, conds.items);
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

const TruthTableAtom = struct { axis: []const u8, value: []const u8 };

/// For every combination of true/false across `atoms`, bind each true atom
/// (`eq` atoms bind `axis=value`, `present` atoms bind any non-empty value)
/// and assert `simplified` evaluates identically to the OR of
/// `original_disjuncts` -- the exact pre-simplification meaning of a
/// dimension's asking condition. Proves simplification never changes
/// eligibility.
fn truthTableEquivalent(
    a: std.mem.Allocator,
    original_disjuncts: []const *const AxisExpr,
    simplified: *const AxisExpr,
    atoms: []const TruthTableAtom,
) !void {
    const combos = @as(usize, 1) << @intCast(atoms.len);
    var combo: usize = 0;
    while (combo < combos) : (combo += 1) {
        var bindings = std.StringHashMap([]const u8).init(a);
        defer bindings.deinit();
        for (atoms, 0..) |atom, i| {
            if ((combo >> @intCast(i)) & 1 == 1) try bindings.put(atom.axis, atom.value);
        }
        var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
        var original_result = false;
        for (original_disjuncts) |d| {
            if (dsl.axis.evaluate(d, &r)) {
                original_result = true;
                break;
            }
        }
        try std.testing.expectEqual(original_result, dsl.axis.evaluate(simplified, &r));
    }
}

fn writeExprToStringForTest(a: std.mem.Allocator, expr: *const AxisExpr) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try dsl.ast.writeExpr(&aw.writer, expr);
    return a.dupe(u8, aw.written());
}

test "simplifyOr: the real signing_work_key 4-term OR reduces to exactly profile=work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mirrors the real corpus: git/config gates the capture on
    // `profile=work and signing_work_key`, allowed_signers on `profile=work
    // and email and signing_work_key`. Discovery's gate-self-reference and
    // conjunction-sibling rules (see recordAxisExpr/combineAndSibling) turn
    // that into these four occurrence conditions for signing_work_key.
    const profile_work: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const email: AxisExpr = .{ .present = "email" };
    const signing: AxisExpr = .{ .present = "signing_work_key" };
    const d1: AxisExpr = .{ .and_ = .{ .left = &profile_work, .right = &email } };
    const d2: AxisExpr = .{ .and_ = .{ .left = &d1, .right = &signing } };
    const d4: AxisExpr = .{ .and_ = .{ .left = &profile_work, .right = &signing } };

    const disjuncts = [_]*const AxisExpr{ &d1, &d2, &profile_work, &d4 };
    const simplified = try simplifyOr(a, &disjuncts);

    try std.testing.expect(simplified.* == .eq);
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, simplified));

    try truthTableEquivalent(a, &disjuncts, simplified, &.{
        .{ .axis = "profile", .value = "work" },
        .{ .axis = "email", .value = "x@y.com" },
        .{ .axis = "signing_work_key", .value = "KEYID" },
    });
}

test "simplifyOr: an or_ nested inside a single occurrence's condition is flattened, then absorbed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const os_darwin: AxisExpr = .{ .eq = .{ .axis = "os", .value = "darwin" } };
    const profile_work: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const and_both: AxisExpr = .{ .and_ = .{ .left = &os_darwin, .right = &profile_work } };
    const inner_or: AxisExpr = .{ .or_ = .{ .left = &profile_work, .right = &and_both } };
    // A single occurrence's own condition, itself an or_: os=darwin or
    // (profile=work or (os=darwin and profile=work)).
    const nested: AxisExpr = .{ .or_ = .{ .left = &os_darwin, .right = &inner_or } };

    const disjuncts = [_]*const AxisExpr{&nested};
    const simplified = try simplifyOr(a, &disjuncts);

    try std.testing.expectEqualStrings("os=darwin or profile=work", try writeExprToStringForTest(a, simplified));

    try truthTableEquivalent(a, &disjuncts, simplified, &.{
        .{ .axis = "os", .value = "darwin" },
        .{ .axis = "profile", .value = "work" },
    });
}

test "simplifyOr: exact-duplicate disjuncts are deduped (absorption keeps equal sets, dedup drops them)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two occurrences under an identical gate produce the same condition.
    // Absorption's strict-superset check deliberately keeps equal atom sets
    // (neither is a strict superset), so only dedup collapses the pair --
    // this pins dedup specifically, which absorption alone would not.
    const os_darwin: AxisExpr = .{ .eq = .{ .axis = "os", .value = "darwin" } };
    const profile_work: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const conj: AxisExpr = .{ .and_ = .{ .left = &os_darwin, .right = &profile_work } };

    const disjuncts = [_]*const AxisExpr{ &conj, &conj };
    const simplified = try simplifyOr(a, &disjuncts);

    // Collapses to the single conjunction -- no residual top-level or_.
    try std.testing.expect(simplified.* == .and_);
    try std.testing.expectEqualStrings("os=darwin and profile=work", try writeExprToStringForTest(a, simplified));

    try truthTableEquivalent(a, &disjuncts, simplified, &.{
        .{ .axis = "os", .value = "darwin" },
        .{ .axis = "profile", .value = "work" },
    });
}

test "discover: signing_work_key's redundant multi-occurrence OR simplifies to profile=work" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.config/git/config",
        "# mox: when profile=work and signing_work_key\nsigningkey = <machine.signing_work_key>\n# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "src/.config/git/allowed_signers",
        "# mox: when profile=work and email and signing_work_key\n<machine.email> namespaces=\"git\" <machine.signing_work_key>\n# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "signing_work_key").?;
    const cond = dim.asking_condition.?;
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, cond));
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

test "discover: an ungated script's declared need leaves a name src/ uses only under a gate unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `onepassword_account` is captured only nested inside `when
    // profile=work`, so its own src/ occurrence is genuinely conditioned
    // (unlike a bare top-level `when profile=work` gate, whose own
    // comparison is always unconditioned by design). The script that
    // declares it runs on every machine, so the OR of the two occurrences
    // is unconditioned.
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when profile=work\nop = <machine.onepassword_account>\n# mox: end\n");
    try writeFile(io, tmp.dir, "scripts/pre/00-op.sh", "#!/bin/sh\n# mox: needs onepassword_account\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "onepassword_account").?;
    try std.testing.expect(dim.asking_condition == null);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-op.sh", dim.provenance.needing_scripts[0]);
    // The needs head is an occurrence, not a source: it links provenance
    // through `needing_scripts` and leaves the source count to src/ alone.
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.source_count);
}

test "discover: a gated script's declared need ORs its gate directory's tuple with the src/ gate on the same name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when profile=work\nvpn = <machine.vpn_host>\n# mox: end\n");
    try writeFile(io, tmp.dir, "scripts/pre/os=linux/00-vpn.sh", "#!/bin/sh\n# mox: needs vpn_host\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const cond = findDim(d, "vpn_host").?.asking_condition.?;

    var b = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &b } };
    try b.put("profile", "personal");
    try b.put("os", "darwin");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
    try b.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
    try b.put("profile", "personal");
    try b.put("os", "linux");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
}

test "discover: an ungated script's scanned token leaves a name src/ uses only under a gate unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No `# mox: needs` head anywhere: the token alone is the script's
    // contract, and `apply.run_scripts` blocks the run on it, so the fact
    // must be asked wherever that ungated script runs -- everywhere.
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when profile=work\nop = <machine.op_account>\n# mox: end\n");
    try writeFile(io, tmp.dir, "scripts/pre/00-op.sh", "#!/bin/sh\necho \"$MOX_FACT_OP_ACCOUNT\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "op_account").?;
    try std.testing.expect(dim.asking_condition == null);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.needing_scripts.len);
    try std.testing.expectEqualStrings("scripts/pre/00-op.sh", dim.provenance.needing_scripts[0]);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.source_count);
}

test "discover: a gated script's scanned token ORs its gate directory's tuple with the src/ gate on the same name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when profile=work\nvpn = <machine.vpn_host>\n# mox: end\n");
    try writeFile(io, tmp.dir, "scripts/pre/os=linux/00-vpn.sh", "#!/bin/sh\necho \"$MOX_FACT_VPN_HOST\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const cond = findDim(d, "vpn_host").?.asking_condition.?;

    var b = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &b } };
    try b.put("profile", "personal");
    try b.put("os", "darwin");
    try std.testing.expect(!dsl.axis.evaluate(cond, &r));
    try b.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
    try b.put("profile", "personal");
    try b.put("os", "linux");
    try std.testing.expect(dsl.axis.evaluate(cond, &r));
}

test "discover: a scanned token matching no known fact registers no dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/00-steam.sh", "#!/bin/sh\necho \"$MOX_FACT_STEAM_LIBRARY\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 0), d.dimensions.len);
}

test "discover: a `# mox: needs` head keeps the tokens it replaces from widening any other name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `profile` is compared only inside a `when locale=ja` body, so its own
    // src/ occurrence is conditioned; the script carries MOX_FACT_PROFILE in
    // its text but declares a different name, so the token must contribute
    // nothing and `profile` must keep the narrow condition.
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: when locale=ja\n# mox: when profile=work\nx = 1\n# mox: end\n# mox: end\n");
    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/00-op.sh",
        "#!/bin/sh\n# mox: needs op_account\necho \"$MOX_FACT_PROFILE\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqualStrings(
        "locale=ja",
        try writeExprToStringForTest(a, findDim(d, "profile").?.asking_condition.?),
    );
    try std.testing.expectEqual(@as(usize, 0), findDim(d, "profile").?.provenance.needing_scripts.len);
}

test "discover: a name whose projection collides with another's is widened by no scanned token" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "Foo-Bar" and "foo_bar" both sanitize to MOX_FACT_FOO_BAR, so neither
    // reaches a script's environment; a token naming it must widen neither.
    // Both comparisons are nested so each has a condition of its own to keep.
    try writeFile(
        io,
        tmp.dir,
        "src/.zshrc",
        "# mox: when locale=ja\n" ++
            "# mox: when Foo-Bar=x\na = 1\n# mox: end\n" ++
            "# mox: when foo_bar=y\nb = 1\n# mox: end\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "scripts/pre/00-both.sh", "#!/bin/sh\necho \"$MOX_FACT_FOO_BAR\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqualStrings(
        "locale=ja",
        try writeExprToStringForTest(a, findDim(d, "Foo-Bar").?.asking_condition.?),
    );
    try std.testing.expectEqualStrings(
        "locale=ja",
        try writeExprToStringForTest(a, findDim(d, "foo_bar").?.asking_condition.?),
    );
}

test "discover: a src/-gated name no script declares as a need keeps its own gate as its asking condition" {
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
        "# mox: when profile=work\nop = <machine.op_account>\nvault = <machine.op_vault>\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "scripts/pre/00-op.sh", "#!/bin/sh\n# mox: needs op_account\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "op_account").?.asking_condition == null);
    try std.testing.expectEqualStrings(
        "profile=work",
        try writeExprToStringForTest(a, findDim(d, "op_vault").?.asking_condition.?),
    );
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

test "discover: a scripts gate directory's own tuple is value-compared and unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/profile=work/00-x.sh", "#!/bin/sh\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "profile").?;
    try std.testing.expect(dim.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), dim.observed_values.len);
    try std.testing.expectEqualStrings("work", dim.observed_values[0]);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a gated script's declared need is asked under its gate directory's tuple" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/profile=work/00-x.sh",
        "#!/bin/sh\n# mox: needs work_token\necho hi\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "work_token").?;
    try std.testing.expectEqualStrings(
        "profile=work",
        try writeExprToStringForTest(a, dim.asking_condition.?),
    );
}

test "discover: a gated script's own when-head atom is asked under its gate directory's tuple too" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/profile=work/00-x.sh",
        "#!/bin/sh\n# mox: when vpn_host\necho hi\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "vpn_host").?;
    try std.testing.expectEqualStrings(
        "profile=work",
        try writeExprToStringForTest(a, dim.asking_condition.?),
    );
}

test "discover: an ungated script's declared need stays unconditioned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "scripts/pre/00-x.sh", "#!/bin/sh\n# mox: needs work_token\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "work_token").?.asking_condition == null);
}

test "discover: a need declared by both a gated and an ungated script is unconditioned, whichever is scanned first" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The gate directory sorts before the ungated script, so the conditioned
    // occurrence is recorded first; the ungated one must still widen it.
    try writeFile(
        io,
        tmp.dir,
        "scripts/pre/arch=arm64/00-x.sh",
        "#!/bin/sh\n# mox: needs shared_token\necho hi\n",
    );
    try writeFile(io, tmp.dir, "scripts/pre/zz.sh", "#!/bin/sh\n# mox: needs shared_token\necho hi\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "shared_token").?.asking_condition == null);
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

// -- fallback-chain capture members ------------------------------------------

test "discover: a chain's leading machine member is a dimension, not a malformed name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "x = <machine.chain_head | env.SOMETHING>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "chain_head").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: a chain's trailing machine member is a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "x = <env.SOMETHING | machine.chain_tail>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "chain_tail").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: a chain's mid machine member is a dimension" {
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
        "x = <env.SOMETHING | machine.chain_mid | data.tools.editor>\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "chain_mid").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: every machine member of one chain is its own dimension" {
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
        "x = <machine.chain_first | env.SOMETHING | machine.chain_second>\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "chain_first").?.roles.captured);
    try std.testing.expect(findDim(d, "chain_second").?.roles.captured);
}

test "discover: a chain's default is no machine member's capture default" {
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
        "x = <env.SOMETHING | machine.chain_defaulted | default \"vim\">\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "chain_defaulted").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), dim.capture_defaults.len);
}

test "discover: a chain member's bad fact name is reported as that member's name alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "x = <env.SOMETHING | machine.Bad-Name>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "Bad-Name") == null);
    try std.testing.expectEqual(@as(usize, 1), d.diagnostics.len);
    const diag = d.diagnostics[0].capture_name;
    try std.testing.expectEqualStrings("src/.zshrc", diag.path);
    try std.testing.expectEqualStrings("Bad-Name", diag.name);
}

// -- captures inside a loop's TOML data source -------------------------------

test "discover: a data row value's fallback chain makes its machine member a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.row_chain | env.HOME>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "row_chain").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: a data row value's plain capture is a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.row_plain>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "row_plain").?.roles.captured);
}

test "discover: a data row's string-array element is a dimension" {
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
        "# mox: for e in \"data/tools.toml\"\n" ++
            "# mox: for d in e.dirs\n" ++
            "v=<d>\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndirs = [\"a\", \"<machine.row_elem>/bin\"]\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "row_elem").?.roles.captured);
}

test "discover: a data row value's capture carries its own `| default`" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.row_defaulted | default \\\"/opt\\\">/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "row_defaulted").?;
    try std.testing.expectEqual(@as(usize, 1), dim.capture_defaults.len);
    try std.testing.expectEqualStrings("/opt", dim.capture_defaults[0]);
}

test "discover: a data row capture read by two loops counts the data file as its one source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "src/.bashrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.shared_row>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expectEqual(@as(usize, 1), findDim(d, "shared_row").?.provenance.source_count);
}

test "discover: a bad fact name in a data row is reported against the data file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.Bad-Row>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "Bad-Row") == null);
    try std.testing.expectEqual(@as(usize, 1), d.diagnostics.len);
    try std.testing.expectEqualStrings("data/tools.toml", d.diagnostics[0].capture_name.path);
    try std.testing.expectEqualStrings("Bad-Row", d.diagnostics[0].capture_name.name);
}

test "discover: a data row capture is conditioned on the loop that reads it" {
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
        "# mox: for e in \"data/tools.toml\" when profile=work\nv=<e.dir>\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.row_gated>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const cond = findDim(d, "row_gated").?.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
}

test "discover: a data row capture read under two different gates is asked under either" {
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
        "# mox: for e in \"data/tools.toml\" when profile=work\nv=<e.dir>\n# mox: end\n",
    );
    try writeFile(
        io,
        tmp.dir,
        "src/.bashrc",
        "# mox: for e in \"data/tools.toml\" when profile=home\nv=<e.dir>\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"<machine.row_two_gates>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const cond = findDim(d, "row_two_gates").?.asking_condition.?;
    try std.testing.expect(cond.* == .or_);
}

test "discover: a per-file `<base>.d/` data source's row capture is a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/tools.toml", "[[tools]]\ndir = \"<machine.overlay_row>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "overlay_row").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 1), dim.provenance.source_count);
}

test "discover: a generator loop's data row capture is a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/leaves.gen",
        "# mox: for h in \"data/hosts.toml\" into \"<h.name>.conf\"\nv=<h.dir>\n# mox: end\n",
    );
    try writeFile(io, tmp.dir, "data/hosts.toml", "[[hosts]]\nname = \"a\"\ndir = \"<machine.gen_row>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "gen_row").?.roles.captured);
}

test "discover: a loop over an enclosing row's array field reads no file of its own" {
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
        "# mox: for e in \"data/tools.toml\"\n" ++
            "# mox: for d in e.dirs\n" ++
            "v=<d>\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndirs = [\"<machine.elem_dim>/bin\"]\n");
    // A fragment that merely shares the field reference's spelling is not a
    // data source: compose resolves `e.dirs` against the enclosing row.
    try writeFile(io, tmp.dir, "src/.zshrc.d/e.dirs", "[[e]]\ndir = \"<machine.decoy_dim>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "elem_dim") != null);
    try std.testing.expect(findDim(d, "decoy_dim") == null);
}

test "discover: a capture in a data file no loop reads is not a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/tools.toml", "[[tools]]\ndir = \"/bin\"\n");
    try writeFile(io, tmp.dir, "data/unread.toml", "[[unread]]\ndir = \"<machine.never_read>/bin\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "never_read") == null);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: a capture in an array the data file's stem does not name is not a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(
        io,
        tmp.dir,
        "data/tools.toml",
        "[[tools]]\ndir = \"/bin\"\n\n[[other]]\ndir = \"<machine.other_array>/bin\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "other_array") == null);
}

test "discover: a data file's comment, key, nested table, and non-row scalar hold no dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/tools.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(
        io,
        tmp.dir,
        "data/tools.toml",
        "# captures allowed, e.g. <machine.comment_dim>/bin\n" ++
            "loose = \"<machine.loose_scalar>/bin\"\n" ++
            "[settings]\n" ++
            "k = \"<machine.nested_table_dim>/bin\"\n" ++
            "[[tools]]\n" ++
            "\"<machine.key_dim>\" = \"v\"\n" ++
            "dir = \"/bin\"\n" ++
            "[tools.meta]\n" ++
            "k = \"<machine.row_nested_dim>/bin\"\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    // None of these four positions is ever interpolated: a comment is dropped
    // by the TOML parse, a key is looked up rather than emitted, a nested
    // table is dropped by the row projection, and a non-row scalar reached by
    // `<data.FILE.KEY>` is spliced verbatim.
    try std.testing.expect(findDim(d, "comment_dim") == null);
    try std.testing.expect(findDim(d, "loose_scalar") == null);
    try std.testing.expect(findDim(d, "nested_table_dim") == null);
    try std.testing.expect(findDim(d, "key_dim") == null);
    try std.testing.expect(findDim(d, "row_nested_dim") == null);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
}

test "discover: an unreadable or malformed data source leaves discovery clean" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: for e in \"data/gone.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "src/.bashrc", "# mox: for e in \"data/broken.toml\"\nv=<e.dir>\n# mox: end\n");
    try writeFile(io, tmp.dir, "data/broken.toml", "[[broken]]\ndir = \"unterminated\n");
    try writeFile(io, tmp.dir, "src/.profile", "y = <machine.still_scanned>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "still_scanned") != null);
    try std.testing.expectEqual(@as(usize, 0), d.diagnostics.len);
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

test "discover: a generator loop's `into` path template capture is discovered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.ssh/config",
        "# mox: for host in \"data/hosts.toml\" into \"<machine.into_site>-<host.name>.conf\"\n" ++
            "# Host <host.name>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "into_site").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
}

test "discover: a generator loop's `into` capture with a declared default is a dimension carrying that default, not an unclaimed default" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.ssh/config",
        "# mox: for host in \"data/hosts.toml\" into \"<machine.into_default_site>-<host.name>.conf\"\n" ++
            "# Host <host.name>\n" ++
            "# mox: end\n",
    );
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: default into_default_site=\"prod\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "into_default_site").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqual(@as(usize, 1), dim.declared_defaults.len);
    try std.testing.expectEqualStrings("prod", dim.declared_defaults[0]);
    try std.testing.expectEqual(@as(usize, 0), d.default_diagnostics.len);
}

test "discover: a for-loop body's capture is conditioned on the loop's own `when`" {
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
        "# mox: for entry in \"data/tools.toml\" when profile=work\n" ++
            "# x <machine.for_gated_dim>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "for_gated_dim").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
}

test "discover: a generator loop's `into` capture is conditioned on the loop's own `when`" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/.ssh/config",
        "# mox: for host in \"data/hosts.toml\" when profile=work into \"<machine.into_gated_site>-<host.name>.conf\"\n" ++
            "# Host <host.name>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "into_gated_site").?;
    try std.testing.expect(dim.roles.captured);
    const cond = dim.asking_condition.?;
    try std.testing.expect(cond.* == .eq);
    try std.testing.expectEqualStrings("profile", cond.eq.axis);
    try std.testing.expectEqualStrings("work", cond.eq.value);
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

// -- marker resolution mirrors compose's, not just the extension table ------

test "discover: a markerless-extension file's capture is still a dimension with its default recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No extension in the marker table, no shebang, no apparent `# mox:`
    // directive: compose still interpolates this capture on its null-marker
    // passthrough, so discovery must see it too.
    try writeFile(io, tmp.dir, "src/.config/tool/settings", "value = <machine.newfact | default \"x\">\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const dim = findDim(d, "newfact").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expect(dim.asking_condition == null);
    try std.testing.expectEqual(@as(usize, 1), dim.capture_defaults.len);
    try std.testing.expectEqualStrings("x", dim.capture_defaults[0]);
}

test "discover: an unrecognized-extension file with a shebang has its gate and capture discovered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(
        io,
        tmp.dir,
        "src/scripts/helper.myext",
        "#!/bin/sh\n" ++
            "# mox: when workonly=yes\n" ++
            "x = <machine.gatedfact>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const gate = findDim(d, "workonly").?;
    try std.testing.expect(gate.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), gate.observed_values.len);
    try std.testing.expectEqualStrings("yes", gate.observed_values[0]);

    const dim = findDim(d, "gatedfact").?;
    try std.testing.expect(dim.roles.captured);
    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("workonly", "no");
    try std.testing.expect(!dsl.axis.evaluate(dim.asking_condition.?, &r));
    try bindings.put("workonly", "yes");
    try std.testing.expect(dsl.axis.evaluate(dim.asking_condition.?, &r));
}

test "discover: an unrecognized-extension file resolves its marker from an apparent `# mox:` directive" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No shebang: the FIRST content line is the `# mox:` directive itself,
    // which is the only signal that `#` is this file's marker.
    try writeFile(
        io,
        tmp.dir,
        "src/config/myapp.weird",
        "# mox: when apparentfact=on\n" ++
            "y = <machine.apparentcapture>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const gate = findDim(d, "apparentfact").?;
    try std.testing.expect(gate.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), gate.observed_values.len);
    try std.testing.expectEqualStrings("on", gate.observed_values[0]);

    const dim = findDim(d, "apparentcapture").?;
    try std.testing.expect(dim.roles.captured);
    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("apparentfact", "off");
    try std.testing.expect(!dsl.axis.evaluate(dim.asking_condition.?, &r));
    try bindings.put("apparentfact", "on");
    try std.testing.expect(dsl.axis.evaluate(dim.asking_condition.?, &r));
}

test "discover: a fully markerless file consuming an already-real fact increments its provenance source_count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `profile` is already real via the shell rc file's capture; a second,
    // fully markerless file -- shaped like the real corpus's
    // src/.config/git/allowed_signers -- also captures it. Before the fix
    // this second source was invisible to discovery entirely (extension-only
    // marker resolution `orelse return`s on a file with no marker at all),
    // silently undercounting `profile`'s provenance.
    try writeFile(io, tmp.dir, "src/.zshrc", "kind = <machine.profile | default \"personal\">\n");
    try writeFile(io, tmp.dir, "src/.config/git/allowed_signers", "sho@example.com namespaces=\"git\" <machine.profile>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const profile = findDim(d, "profile").?;
    try std.testing.expectEqual(@as(usize, 2), profile.provenance.source_count);
}

test "discover: a recognized-extension file's discovery is unchanged (mutation guard)" {
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
            "name = <machine.git_name>\n" ++
            "# mox: end\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);

    const profile = findDim(d, "profile").?;
    try std.testing.expect(profile.roles.value_compared);
    try std.testing.expectEqual(@as(usize, 1), profile.observed_values.len);
    try std.testing.expectEqualStrings("work", profile.observed_values[0]);

    const git_name = findDim(d, "git_name").?;
    try std.testing.expect(git_name.roles.captured);
    var bindings = std.StringHashMap([]const u8).init(a);
    var r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put("profile", "personal");
    try std.testing.expect(!dsl.axis.evaluate(git_name.asking_condition.?, &r));
    try bindings.put("profile", "work");
    try std.testing.expect(dsl.axis.evaluate(git_name.asking_condition.?, &r));
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
    // Must return (not hang, not crash) regardless of the exact result, so
    // the wall clock is what the assertion is on: a regression to unbounded
    // recursion fails here instead of hanging the suite forever.
    const started = std.Io.Clock.awake.now(io);
    _ = try discover(a, io, repo);
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(elapsed_ms < 30_000);
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

test "discover: a Cat A overlay's plain capture is a dimension, asked when its overlay tuple holds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/app.toml", "[core]\nname = \"app\"\n");
    try writeFile(io, tmp.dir, "src/app.toml.d/profile=work", "[work]\nvalue = \"<machine.overlay_fact>\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "overlay_fact").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, dim.asking_condition.?));
}

test "discover: a Cat A overlay's fallback-chain capture is a dimension, not left to resolve past silently" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/app.toml", "[core]\nname = \"app\"\n");
    try writeFile(io, tmp.dir, "src/app.toml.d/profile=work", "[work]\nvalue = \"<machine.overlay_fact | env.HOME>\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "overlay_fact").?;
    try std.testing.expect(dim.roles.captured);
    // A chain's members carry no interview default: the `| default` rescues an
    // exhausted chain, not one member.
    try std.testing.expectEqual(@as(usize, 0), dim.capture_defaults.len);
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, dim.asking_condition.?));
}

test "discover: a baseless .d/ overlay's capture is a dimension, asked when its overlay tuple holds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No `src/gated.toml`: the `.d/` alone is whole-file axis gating, and the
    // single matching layer composes verbatim.
    try writeFile(io, tmp.dir, "src/gated.toml.d/profile=work", "value = \"<machine.gated_overlay_fact>\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "gated_overlay_fact").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, dim.asking_condition.?));
}

test "discover: a raw-line-merged gitconfig overlay's capture is a dimension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n  name = me\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/profile=work", "[user]\n  email = <machine.work_email>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "work_email").?;
    try std.testing.expect(dim.roles.captured);
    try std.testing.expectEqualStrings("profile=work", try writeExprToStringForTest(a, dim.asking_condition.?));
}

test "discover: a multi-pair overlay tuple conditions its capture on every pair" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n  name = me\n");
    try writeFile(
        io,
        tmp.dir,
        "src/.gitconfig.d/holt_backend=gdrive+profile=work",
        "[user]\n  email = <machine.work_email>\n",
    );

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "work_email").?;
    try std.testing.expectEqualStrings(
        "holt_backend=gdrive and profile=work",
        try writeExprToStringForTest(a, dim.asking_condition.?),
    );
}

test "discover: an overlay filename's stripped and verbatim tuples are both asked under" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `hostname=host.local` matches either as the whole written value or as
    // the extension-stripped `host`; compose tries both, so both are asked
    // under.
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n  name = me\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/hostname=host.local", "[user]\n  email = <machine.host_email>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "host_email").?;
    try std.testing.expectEqualStrings(
        "hostname=host or hostname=host.local",
        try writeExprToStringForTest(a, dim.asking_condition.?),
    );
}

test "discover: an overlay filename's stripped and verbatim readings are both observed values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Compose matches `zone=eu.local` as the whole written value first and as
    // the extension-stripped `eu` second, so the answer that selects it under
    // either reading is one the interview offers and accepts.
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n  name = me\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/zone=eu.local", "[user]\n  email = e@eu\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "zone").?;
    try std.testing.expectEqual(@as(usize, 2), dim.observed_values.len);
    try std.testing.expectEqualStrings("eu", dim.observed_values[0]);
    try std.testing.expectEqualStrings("eu.local", dim.observed_values[1]);
}

test "discover: a region fragment filename's stripped and verbatim readings are both observed values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/kind.lua", "# mox: from \"zone\"\nlocal M = {}\n# mox: end\n");
    try writeFile(io, tmp.dir, "src/kind.lua.d/zone/eu.local", "M.zone = \"eu\"\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    const dim = findDim(d, "zone").?;
    try std.testing.expectEqual(@as(usize, 2), dim.observed_values.len);
    try std.testing.expectEqualStrings("eu", dim.observed_values[0]);
    try std.testing.expectEqualStrings("eu.local", dim.observed_values[1]);
}

test "discover: a Cat B overlay's capture is no dimension, since compose never reads an overlay there" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/hook.sh", "echo base\n");
    try writeFile(io, tmp.dir, "src/hook.sh.d/profile=work", "echo <machine.never_composed>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "never_composed") == null);
}

test "discover: a Cat C overlay's capture is no dimension, since compose copies the layer verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/id.pem", "BASE\n");
    try writeFile(io, tmp.dir, "src/id.pem.d/profile=work", "<machine.never_interpolated>\n");

    const repo = try tmpAbsPath(a, &tmp, "");
    const d = try discover(a, io, repo);
    try std.testing.expect(findDim(d, "never_interpolated") == null);
}
