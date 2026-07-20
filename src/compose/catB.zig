const std = @import("std");
const Env = @import("env").Env;
const source = @import("../source/root.zig");
const dsl = @import("../dsl/root.zig");
const match_mod = @import("match.zig");
const pacifier = @import("pacifier.zig");
const data_mod = @import("../data/root.zig");
const interp = @import("interp.zig");
const machine = @import("../machine/root.zig");
const secret = @import("../secret/root.zig");
const prov_mod = @import("../provenance/root.zig");

const Io = std.Io;
const ManagedFile = source.tree.ManagedFile;
const AxisTuple = source.tree.AxisTuple;
const Fragment = source.tree.Fragment;
const Segment = prov_mod.map.Segment;
const Origin = prov_mod.map.Origin;

/// Output-buffer wrapper that records line provenance as content is emitted.
/// Every emission goes through `markSince`: emit bytes into `buf` exactly as
/// before, then attribute the logical lines just written to an origin. With
/// `prov == null` it is a plain byte sink and only advances the line counter.
const Emitter = struct {
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    prov: ?*std.ArrayList(Segment),
    line: u32 = 0,

    fn markSince(self: *Emitter, start: usize, origin: Origin) !void {
        const n = prov_mod.map.lineCount(self.buf.items[start..]);
        if (n == 0) return;
        if (self.prov) |p| try prov_mod.map.append(self.arena, p, self.line, n, origin);
        self.line += n;
    }
};

/// Emit one base line: interpolate `<machine.X>`/`<secret:...>`, append it with
/// its trailing newline, and attribute provenance PER LINE -- `.secret` only
/// when this line resolved an inline secret (so diffs and snapshots redact just
/// that line, never the whole file), `.interpolated` when machine interp
/// otherwise rewrote it, else `.base`. Both the directive loop and the
/// directiveless passthrough go through here so their provenance matches.
fn emitBaseLine(em: *Emitter, arena: std.mem.Allocator, line: []const u8, line_no: u32, machine_present: bool, ctx: interp.Ctx) !void {
    var line_has_secret = false;
    const interpolated = if (machine_present) blk: {
        const exp = try interp.expandTracked(arena, line, null, ctx);
        line_has_secret = exp.secret;
        break :blk exp.bytes;
    } else line;
    const start = em.buf.items.len;
    try em.buf.appendSlice(arena, interpolated);
    try em.buf.append(arena, '\n');
    const origin: Origin = if (line_has_secret)
        .secret
    else if (machine_present and !std.mem.eql(u8, interpolated, line))
        .{ .interpolated = .{ .origin_line = line_no } }
    else
        .{ .base = .{ .line = line_no } };
    try em.markSince(start, origin);
}

/// Per-line non-secret origin policy for `emitSecretAwareBody`.
const BodyOrigin = union(enum) {
    /// The same origin for every non-secret line (literal/overlay/when-gate
    /// bodies, or one loop row).
    flat: Origin,
    /// A fragment: non-secret line `i` maps to source line `first_line + i`.
    fragment: struct { file: ManagedFile, path: []const u8, first_line: u32 },
};

fn bodyLineOrigin(policy: BodyOrigin, i: u32) Origin {
    return switch (policy) {
        .flat => |o| o,
        .fragment => |f| fragmentOrigin(f.file, f.path, f.first_line + i),
    };
}

/// How a body's trailing newline is written, matching the two conventions the
/// call sites had before this helper unified them:
///  - `single`: exactly one trailing newline (fragment / region pick, which
///    used `appendWithTrailingNewline`).
///  - `always_add`: a newline after every line including a body's own trailing
///    empty line (literal / when-gate / loop, which used `appendSlice` + a bare
///    `\n`). A whole-file when-gate body keeps its own final `\n`, so this
///    doubles it -- the compose function's post-loop pop trims the extra.
const BodyTrailing = enum { single, always_add };

/// Emit a body (fragment, region pick, literal/overlay body, when-gate body, or
/// a loop row) so that ONLY lines resolving an inline secret are `.secret`;
/// every other line gets `bodyLineOrigin(policy, i)`. With no secret -- the
/// common case -- the body is emitted whole in a single span, byte- and
/// provenance-identical to the site's original append. A secret makes it
/// re-emit line by line over the UNEXPANDED body (re-expanding already-resolved
/// bytes would find no `<secret:URI>` and fail to redact it): a whole-body
/// `.secret` mark would redact the body's non-secret lines out of diffs and
/// snapshots and corrupt them on rollback. `interp_on` mirrors the caller's
/// `ctx.machine != null` gate (the loop passes true and its row `record`).
fn emitSecretAwareBody(
    em: *Emitter,
    arena: std.mem.Allocator,
    body: []const u8,
    ctx: interp.Ctx,
    interp_on: bool,
    record: ?*const std.StringHashMap(data_mod.value.Value),
    trailing: BodyTrailing,
    policy: BodyOrigin,
) !void {
    var whole_secret = false;
    const expanded = if (interp_on) blk: {
        const exp = try interp.expandTracked(arena, body, record, ctx);
        whole_secret = exp.secret;
        break :blk exp.bytes;
    } else body;
    if (!whole_secret) {
        const start = em.buf.items.len;
        switch (trailing) {
            .single => try appendWithTrailingNewline(arena, em.buf, expanded),
            .always_add => {
                try em.buf.appendSlice(arena, expanded);
                try em.buf.append(arena, '\n');
            },
        }
        try em.markSince(start, bodyLineOrigin(policy, 0));
        return;
    }
    // `single` collapses a body's own trailing newline to one and so drops its
    // empty final segment; `always_add` emits that segment too, doubling the
    // newline exactly as the pre-helper append did (trimmed by the post-loop pop).
    const drop_final = trailing == .single and body.len > 0 and body[body.len - 1] == '\n';
    var lines = std.mem.splitScalar(u8, body, '\n');
    var i: u32 = 0;
    while (lines.next()) |line| {
        if (drop_final and lines.peek() == null and line.len == 0) break;
        var line_secret = false;
        const line_bytes = if (interp_on) blk: {
            const exp = try interp.expandTracked(arena, line, record, ctx);
            line_secret = exp.secret;
            break :blk exp.bytes;
        } else line;
        const start = em.buf.items.len;
        try em.buf.appendSlice(arena, line_bytes);
        try em.buf.append(arena, '\n');
        try em.markSince(start, if (line_secret) .secret else bodyLineOrigin(policy, i));
        i += 1;
    }
}

/// Origin for a fragment emitted from `frag_abs`: `.private` when the file
/// lives under the private layer (routes only there), else `.fragment`.
/// `first_line` is the 1-based source line the first emitted line came from;
/// it is 2 when a pacifier line was stripped, so commit maps edits back to the
/// right line instead of assuming a 1:1 start at line 1.
fn fragmentOrigin(file: ManagedFile, frag_abs: []const u8, first_line: u32) Origin {
    if (file.private_dir.len > 0 and std.mem.startsWith(u8, frag_abs, file.private_dir))
        return .{ .private = .{ .path = frag_abs, .line = first_line } };
    return .{ .fragment = .{ .path = frag_abs, .line = first_line } };
}

/// Origin for a directive's literal fallback body: attributed to the whole
/// base layer (no line-level mapping), so commit reports it as manual rather
/// than risk mis-editing a directive marker line.
fn overlayOrigin(file: ManagedFile) Origin {
    const path = if (file.source_base_abs.len > 0) file.source_base_abs else file.source_base_path;
    return .{ .overlay = .{ .path = path } };
}

pub const ComposeError = error{
    NoBase,
    NoMatchingFragment,
    UnsupportedDirective,
    UnknownCommentMarker,
    DataSourceArrayNotFound,
    RecursionTooDeep,
    UnknownLoopVariable,
    LoopSourceFieldNotFound,
    /// A `for ... into` reached the normal (single-file) loop composer. A
    /// GENERATOR loop is only valid as a file's sole top-level directive and is
    /// intercepted by `composeGenerator`; reaching `emitForLoop` means a
    /// top-level `for ... into` shares the file with other content/directives.
    IntoOnNonGenerator,
    /// A generator row rendered an `into` path that escapes its base (absolute
    /// or contains `..`), or an empty path.
    GeneratedPathEscapes,
    /// Two generator rows rendered the same `into` path.
    DuplicateGeneratedPath,
};

const max_file_bytes: usize = 64 * 1024 * 1024;

/// Explicit error set for the mutually-recursive emit functions
/// (`emitDirective` <-> `emitParsedBody` <-> `emitForLoop` ...): an inferred
/// set cannot resolve across the recursion cycle.
const EmitError = Io.Dir.ReadFileAllocError ||
    interp.InterpError ||
    interp.LintError ||
    dsl.driver.DriverError ||
    data_mod.source.LoadError ||
    secret.resolver.ResolveError ||
    ComposeError ||
    error{ DataSourceNotFound, NoRepoRootForSharedData, IncludeFragmentNotFound };

/// Recursion cap for nested region bodies (`for`/`when` inside `for`, ...),
/// mirroring the expression parsers' depth cap. Real dotfile nesting is shallow
/// (2 levels); this bounds a pathological or hostile structure so compose
/// terminates instead of overflowing the stack.
const max_nest_depth: u32 = 128;

/// Recursion context threaded through nested region bodies. `record` is the
/// innermost loop row (an empty map outside any loop), used by a nested
/// `when`/`where` row predicate and by legacy `<entry.X>` / bare-field interp;
/// the full loop scope (variable-name keyed) travels in `ctx.scope`.
const Nest = struct {
    marker: []const u8,
    record: *const std.StringHashMap(data_mod.value.Value),
    /// True inside an enclosing `for`: content lines are prefix-stripped and
    /// interpolated unconditionally, and a `when` gate uses its row condition.
    in_for: bool,
    depth: u32,
};

/// Build the capture-expansion context for a file: the machine facts, the
/// roots `<data.FILE.KEY>` needs (private layer shadows repo), and the secret
/// resolver for `<secret:URI>` (null on read paths, which emit placeholders).
fn interpCtx(
    io: Io,
    file: ManagedFile,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?SecretCtx,
    diag: ?*interp.Diag,
) interp.Ctx {
    return .{
        .io = io,
        .machine = machine_state_opt,
        .repo_dir = file.repo_dir,
        .private_dir = file.private_dir,
        .secrets = if (secrets) |sc| .{ .env = sc.env, .cache = sc.cache } else null,
        .diag = diag,
    };
}

/// Compose a Category B managed file. Returns the bytes that should be
/// written to the live path, or null if the whole file is gated and the
/// gate evaluates false. Memory is owned by `arena`.
///
/// Thin wrapper that disables secret resolution; secret directives emit
/// a `<SECRET:uri>` placeholder. Use `composeWithSecrets` to resolve.
pub fn compose(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
) !?[]u8 {
    return composeTracked(arena, io, file, bindings, machine_state_opt, null, null, null);
}

/// Everything secret resolution needs: the process environment (for `env:`
/// URIs and backend subprocesses) and the per-invocation lookup cache.
pub const SecretCtx = struct {
    env: Env,
    cache: *secret.cache.Cache,
};

/// Compose a Category B managed file with secret resolution.
///
/// With a `SecretCtx`, `# mox: secret "<uri>"` directives resolve through
/// the resolver (consulting/populating the cache) and a resolution failure
/// fails the file's compose. With null, secret directives emit
/// `<SECRET:uri>` placeholders (parse/lint-only paths).
pub fn composeWithSecrets(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?SecretCtx,
) !?[]u8 {
    return composeTracked(arena, io, file, bindings, machine_state_opt, secrets, null, null);
}

/// Compose with optional provenance recording. When `prov` is non-null, every
/// emitted run of output lines is attributed to its source (base line,
/// fragment, loop row, secret, ...) so `mox commit` can route user edits back.
pub fn composeTracked(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    if (!file.has_base) return error.NoBase;

    const ctx = interpCtx(io, file, machine_state_opt, secrets, diag);

    const base_content = try Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes));

    const marker = markerForFile(file.source_base_path, base_content) orelse {
        // No signal at all. Pass through verbatim — directiveless config
        // files shouldn't need a marker — but still run `<machine.X>` interp
        // so user-baked facts substitute consistently with the directive
        // path.
        if (machine_state_opt) |_| {
            // Emit line by line so an inline secret marks only its own line
            // `.secret`, not the whole file: a false whole-file mark would
            // redact every non-secret line out of diffs and snapshots (and a
            // rollback would then restore the redaction placeholder over them).
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(arena);
            var em: Emitter = .{ .arena = arena, .buf = &out, .prov = prov };
            var lines = std.mem.splitScalar(u8, base_content, '\n');
            var ln: u32 = 0;
            while (lines.next()) |line| {
                ln += 1;
                try emitBaseLine(&em, arena, line, ln, true, ctx);
            }
            if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
            if (prov) |p| prov_mod.map.truncateTo(p, prov_mod.map.lineCount(out.items));
            return @as(?[]u8, try out.toOwnedSlice(arena));
        }
        try recordWholeBase(arena, prov, base_content);
        return base_content;
    };

    var parse_loc: dsl.driver.ParseLoc = .{};
    const parsed = dsl.driver.parseFile(arena, base_content, marker, &parse_loc) catch |e| {
        // Point the user at the malformed line: a bare "UnexpectedCharacter" in a
        // long config is far harder to fix than "line 12: secret env:X".
        if (ctx.diag) |d| {
            if (parse_loc.line > 0) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "line {d}: {s}", .{ parse_loc.line, parse_loc.directive }) catch parse_loc.directive;
                d.set(msg);
            }
        }
        return e;
    };

    // Whole-file when_gate: a `when ...` directive without a matching `end`
    // (gating to EOF) controls whether the file materializes at all. The
    // directive must be at the very top of the file — line 1, OR line 2 if
    // line 1 is a shebang (so executable scripts can keep `#!` as line 1
    // while still being whole-file gated) — AND it must actually run to EOF.
    // A scoped `when ... end` block shares the `.when_gate` kind but is
    // terminated; without the `to_eof` check a top-of-file scoped gate is
    // misread as whole-file and its trailing content is silently dropped.
    const top_line: u32 = if (std.mem.startsWith(u8, base_content, "#!")) 2 else 1;
    if (parsed.directives.len > 0) {
        const first = parsed.directives[0];
        if (first.kind == .when_gate and first.start_line <= top_line and first.kind.when_gate.to_eof) {
            if (first.kind.when_gate.when) |w| {
                if (!dsl.axis.evaluate(w, bindings)) return null;
            }
        }
    }

    var empty_record = std.StringHashMap(data_mod.value.Value).init(arena);
    const top_nest: Nest = .{ .marker = marker, .record = &empty_record, .in_for = false, .depth = 0 };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var em: Emitter = .{ .arena = arena, .buf = &out, .prov = prov };

    var lines = std.mem.splitScalar(u8, base_content, '\n');
    var line_no: u32 = 0;
    var dir_idx: usize = 0;

    while (lines.next()) |line| {
        line_no += 1;

        if (dir_idx < parsed.directives.len) {
            const d = parsed.directives[dir_idx];
            if (line_no >= d.start_line and line_no <= d.end_line) {
                if (line_no == d.start_line) {
                    try emitDirective(arena, io, &em, file, d, bindings, ctx, secrets, top_nest);
                }
                if (line_no == d.end_line) {
                    dir_idx += 1;
                }
                continue;
            }
        }

        // Interpolate `<machine.X>` in the base content too, so users can
        // bake machine-derived values directly into the source without
        // having to wrap each one in a `replace from` region. A line carrying
        // an inline secret becomes `.secret` (never routed, kept out of the
        // cleartext cache); one interp otherwise rewrote is `.interpolated`
        // (left manual, so the expanded value is not baked back into source).
        try emitBaseLine(&em, arena, line, line_no, machine_state_opt != null, ctx);
    }

    // The split-and-rejoin loop always introduces one extra trailing newline
    // (an empty final segment when input ends with '\n', or a forced newline
    // on the last line when it didn't; likewise a `when`-gate body that runs
    // to EOF already carries its own trailing newline). Drop it so the
    // output's final-newline shape matches the input's, then trim provenance
    // to the surviving line count so segments stay aligned 1:1 with the diff.
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    if (prov) |p| prov_mod.map.truncateTo(p, prov_mod.map.lineCount(out.items));

    return try out.toOwnedSlice(arena);
}

/// One file produced by a generator (`for ... into`): the resolved live path,
/// its composed body, the per-file provenance, and secret-attribution flags.
pub const GeneratedFile = struct {
    live_path: []const u8,
    content: []u8,
    prov: []Segment,
    /// True when any line resolved an inline secret (kept out of the applied-
    /// content cache and snapshots, exactly as for a normal file).
    contains_secret: bool,
    /// True when a dedicated-manager (op://|pass://) secret resolved into the
    /// body, so apply auto-restricts the file to 0600.
    manager_secret: bool,
};

/// Compose a GENERATOR: a managed file whose SOLE top-level directive is a
/// `for ... into "<template>"`. Returns one `GeneratedFile` per data row (after
/// `where`), each at the rendered `<template>` path resolved against the
/// generator's own target directory; the generator's own path never
/// materializes. Returns null when `file` is NOT a generator (the caller then
/// composes it normally). Rows come from the data source (private layer shadows
/// repo). An empty/zero-row source (or a false loop-level `when`) yields an
/// empty slice, not null. `diag`, when set, receives the failing item's text on
/// an error, so the caller can name what failed.
/// Any non-blank line outside the `[start_line, end_line]` span. Used to reject a
/// generator source that mixes its `for ... into` with other content (blank
/// lines, e.g. a trailing newline, are allowed).
fn hasContentOutside(content: []const u8, start_line: u32, end_line: u32) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    var ln: u32 = 0;
    while (it.next()) |line| {
        ln += 1;
        if (ln >= start_line and ln <= end_line) continue;
        if (std.mem.trim(u8, line, " \t\r").len > 0) return true;
    }
    return false;
}

pub fn composeGenerator(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?SecretCtx,
    diag: ?*interp.Diag,
) EmitError!?[]GeneratedFile {
    if (!file.has_base or file.source_base_abs.len == 0) return null;

    const base_content = try Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes));
    const marker = markerForFile(file.source_base_path, base_content) orelse return null;
    // A parse error here is not a generator decision: let the normal compose
    // path re-parse and report it with a source location.
    const parsed = dsl.driver.parseFile(arena, base_content, marker, null) catch return null;
    if (parsed.directives.len != 1 or parsed.directives[0].kind != .for_loop) return null;
    const loop = parsed.directives[0].kind.for_loop;
    if (loop.into == null) return null;
    // A generator is ONLY its `for ... into` block -- composeGenerator emits just
    // the loop body per row, so any stray top-level content would be silently
    // dropped. Fall through when the block is not the whole file; the normal
    // path then rejects the for-into loudly (IntoOnNonGenerator).
    const d0 = parsed.directives[0];
    if (hasContentOutside(base_content, d0.start_line, d0.end_line)) return null;
    const template = loop.into.?;

    var ctx = interpCtx(io, file, machine_state_opt, secrets, diag);

    var outputs: std.ArrayList(GeneratedFile) = .empty;
    errdefer outputs.deinit(arena);

    // Loop-level `when` (axis grammar, machine-gated): a false gate produces
    // zero files -- and prunes any prior set, exactly like an empty source.
    if (loop.when) |expr_ptr| {
        if (!dsl.axis.evaluate(expr_ptr, bindings)) return try outputs.toOwnedSlice(arena);
    }

    try interp.lint(arena, template);

    const records = try loadGeneratorRows(arena, io, file, loop.data_source, diag);

    const scope = try prependFrame(arena, ctx.scope, loop.variable);
    ctx.scope = scope;

    const parsed_body = try parseNestBody(arena, loop.body_template, marker, true);
    const nested = parsed_body.directives.len > 0;
    const stripped = if (!nested) try stripBody(arena, loop.body_template, marker) else "";
    if (!nested) try interp.lint(arena, stripped);

    const base_dir = std.fs.path.dirname(file.live_path) orelse file.live_path;

    // Reject two rows rendering the same path: an unintended collision would
    // otherwise silently drop one row's file (last write wins).
    var seen = std.StringHashMap(void).init(arena);

    for (records) |*record_ptr| {
        scope[0] = .{ .name = loop.variable, .value = .{ .record = record_ptr } };
        if (loop.where) |w| {
            if (!try evalRow(arena, w, scope, bindings, ctx.diag)) continue;
        }

        // Render the path template in the row scope, then guard it: an absolute
        // or `..`-bearing (or empty) result must never join outside the target
        // dir. This is the data-safety gate on where a generated file can land.
        const rendered = try interp.expand(arena, template, record_ptr, ctx);
        if (rendered.len == 0 or source.path.keyEscapes(rendered)) {
            if (ctx.diag) |d| d.set(if (rendered.len == 0) template else rendered);
            return error.GeneratedPathEscapes;
        }
        if ((try seen.getOrPut(rendered)).found_existing) {
            if (ctx.diag) |d| d.set(rendered);
            return error.DuplicateGeneratedPath;
        }
        const live_path = try source.path.joinKeyOnto(arena, base_dir, rendered);

        var row_diag: interp.Diag = .{};
        var row_ctx = ctx;
        row_ctx.diag = &row_diag;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);
        var prov: std.ArrayList(Segment) = .empty;
        var em: Emitter = .{ .arena = arena, .buf = &out, .prov = &prov };

        composeGeneratorBody(arena, io, &em, file, bindings, row_ctx, secrets, marker, loop.body_template, parsed_body, nested, stripped, record_ptr) catch |e| {
            if (diag) |d| if (row_diag.capture()) |c| d.set(c);
            return e;
        };

        // A generated file is complete: keep the trailing newline the emit gives
        // its last line. The body template has no empty final segment, so there
        // is no extra to drop (unlike composeTracked's whole-file pass).
        prov_mod.map.truncateTo(&prov, prov_mod.map.lineCount(out.items));

        const contains_secret = prov_mod.map.hasSecret(prov.items);
        try outputs.append(arena, .{
            .live_path = live_path,
            .content = try out.toOwnedSlice(arena),
            .prov = try prov.toOwnedSlice(arena),
            .contains_secret = contains_secret,
            .manager_secret = row_diag.manager_secret,
        });
    }

    return try outputs.toOwnedSlice(arena);
}

/// Emit one generator row's body into `em`: the recursive walk when the body
/// carries nested directives, else the fast flat emit -- the same two paths
/// `emitForLoop` takes per row, so a generated file composes identically to a
/// single-file loop's row.
fn composeGeneratorBody(
    arena: std.mem.Allocator,
    io: Io,
    em: *Emitter,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    ctx: interp.Ctx,
    secrets: ?SecretCtx,
    marker: []const u8,
    body_template: []const u8,
    parsed_body: dsl.ast.ParsedFile,
    nested: bool,
    stripped: []const u8,
    record_ptr: *const RecordMap,
) EmitError!void {
    if (nested) {
        const inner: Nest = .{ .marker = marker, .record = record_ptr, .in_for = true, .depth = 1 };
        try emitParsedBody(arena, io, em, file, bindings, ctx, secrets, body_template, parsed_body, inner);
    } else {
        try emitSecretAwareBody(em, arena, stripped, ctx, true, record_ptr, .always_add, .{ .flat = overlayOrigin(file) });
    }
}

/// Load a generator's data rows from its file-based source (a `/`-bearing
/// repo-relative path, private layer shadowing repo; or a bare per-file name).
/// Mirrors `emitForLoop`'s file branch; a top-level generator has no enclosing
/// scope, so the scope-relative array-element form does not apply.
fn loadGeneratorRows(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    data_source: []const u8,
    diag: ?*interp.Diag,
) EmitError![]RecordMap {
    const data_path = blk: {
        if (std.mem.indexOfScalar(u8, data_source, '/') != null) {
            if (file.private_dir.len > 0) {
                const priv = try source.path.joinKeyOnto(arena, file.private_dir, data_source);
                if (fileExists(io, priv)) break :blk priv;
            }
            if (file.repo_dir.len == 0) return error.NoRepoRootForSharedData;
            break :blk try source.path.joinKeyOnto(arena, file.repo_dir, data_source);
        }
        const overlay_dir = try std.fmt.allocPrint(arena, "{s}.d", .{file.source_base_abs});
        break :blk try source.path.joinKeyOnto(arena, overlay_dir, data_source);
    };

    const arr_map = data_mod.source.loadFile(arena, io, data_path) catch |e| switch (e) {
        error.FileNotFound => {
            if (diag) |dg| dg.set(data_path);
            return error.DataSourceNotFound;
        },
        else => return e,
    };
    const stem = filenameStem(data_source);
    // A present-but-empty array (`stem = []`) is a legitimate ZERO rows: the
    // deliberate way to empty a generator so its leaves are pruned. An ABSENT
    // array -- a 0-byte or truncated file, or a mistyped array declaration -- is
    // an error, not zero rows, so a corruption cannot silently prune every
    // produced file. This mirrors the inline loop's protection.
    return arr_map.get(stem) orelse {
        if (diag) |dg| dg.set(data_path);
        return error.DataSourceArrayNotFound;
    };
}

/// Record a single whole-file `.base` segment for a verbatim directiveless
/// passthrough (no interpolation, so no secret can appear). The interpolated
/// passthrough emits line by line instead, to attribute secrets per line.
fn recordWholeBase(arena: std.mem.Allocator, prov: ?*std.ArrayList(Segment), bytes: []const u8) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    try p.append(arena, .{ .out_start = 0, .out_len = n, .origin = .{ .base = .{ .line = 1 } } });
}

fn emitDirective(
    arena: std.mem.Allocator,
    io: Io,
    em: *Emitter,
    file: ManagedFile,
    d: dsl.ast.Directive,
    bindings: *const std.StringHashMap([]const u8),
    ctx: interp.Ctx,
    secrets: ?SecretCtx,
    nest: Nest,
) EmitError!void {
    const out = em.buf;
    switch (d.kind) {
        .include => |inc| {
            if (inc.when) |expr_ptr| {
                if (!dsl.axis.evaluate(expr_ptr, bindings)) return;
            }
            try emitFragmentByPath(arena, io, em, file, inc.path, ctx);
        },
        .replace => |rep| {
            if (rep.from) |dir_name| {
                if (try pickFragmentFromRegion(arena, io, file, dir_name, bindings)) |picked| {
                    try emitSecretAwareBody(em, arena, picked.text, ctx, ctx.machine != null, null, .single, .{
                        .fragment = .{ .file = file, .path = picked.path, .first_line = picked.first_line },
                    });
                } else {
                    try emitLiteralBody(arena, em, file, rep.body, ctx);
                }
                return;
            }
            const expr_ptr = rep.when orelse {
                try emitLiteralBody(arena, em, file, rep.body, ctx);
                return;
            };
            if (dsl.axis.evaluate(expr_ptr, bindings)) {
                try emitFragmentByPath(arena, io, em, file, rep.path.?, ctx);
            } else {
                try emitLiteralBody(arena, em, file, rep.body, ctx);
            }
        },
        .append => |a| {
            try emitLiteralBody(arena, em, file, a.body, ctx);
            const cond = if (a.when) |expr_ptr| dsl.axis.evaluate(expr_ptr, bindings) else true;
            if (cond) try emitFragmentByPath(arena, io, em, file, a.path, ctx);
        },
        .prepend => |p| {
            const cond = if (p.when) |expr_ptr| dsl.axis.evaluate(expr_ptr, bindings) else true;
            if (cond) try emitFragmentByPath(arena, io, em, file, p.path, ctx);
            try emitLiteralBody(arena, em, file, p.body, ctx);
        },
        .remove => |r| {
            if (!dsl.axis.evaluate(r.when, bindings)) {
                try emitLiteralBody(arena, em, file, r.body, ctx);
            }
        },
        .from => |f| {
            if (try pickFragmentFromRegion(arena, io, file, f.dir, bindings)) |picked| {
                try emitSecretAwareBody(em, arena, picked.text, ctx, ctx.machine != null, null, .single, .{
                    .fragment = .{ .file = file, .path = picked.path, .first_line = picked.first_line },
                });
            } else {
                try emitLiteralBody(arena, em, file, f.body, ctx);
            }
        },
        .when_gate => |w| {
            // OUTSIDE a loop the condition is an axis expression; INSIDE one it
            // is a row expression against the loop scope (any nesting level) plus
            // machine bindings.
            const pass = if (nest.in_for)
                try evalRow(arena, w.row_when.?, ctx.scope, bindings, ctx.diag)
            else
                dsl.axis.evaluate(w.when.?, bindings);
            if (!pass) return;
            // An EMPTY region (opener immediately followed by end, no body
            // lines) emits nothing; a region with body lines -- even a single
            // blank one -- emits them. w.body is "" for both an empty region
            // and a one-blank-line body, so the line span distinguishes them
            // (a blank body line must survive; an absent body must not add one).
            if (d.end_line <= d.start_line + 1) return;
            const parsed_body = try parseNestBody(arena, w.body, nest.marker, nest.in_for);
            if (parsed_body.directives.len == 0) {
                // No nested directives: emit the whole body in one span, as the
                // flat when-gate path always did. Inside a loop its content
                // lines are prefix-stripped and interpolated unconditionally.
                const body = if (nest.in_for) try stripBody(arena, w.body, nest.marker) else w.body;
                const rec: ?*const RecordMap = if (nest.in_for) nest.record else null;
                const interp_on = nest.in_for or ctx.machine != null;
                try emitSecretAwareBody(em, arena, body, ctx, interp_on, rec, .always_add, .{ .flat = overlayOrigin(file) });
                return;
            }
            const inner: Nest = .{ .marker = nest.marker, .record = nest.record, .in_for = nest.in_for, .depth = nest.depth + 1 };
            try emitParsedBody(arena, io, em, file, bindings, ctx, secrets, w.body, parsed_body, inner);
        },
        .for_loop => |loop| try emitForLoop(arena, io, em, file, loop, bindings, ctx, secrets, nest),
        .secret => |s| {
            // A dedicated-manager secret marks the file for auto-0600 (set on
            // the resolve path before resolution; a failure aborts the compose).
            if (secrets != null and interp.isManagerSecretUri(s.uri)) {
                if (ctx.diag) |sink| sink.manager_secret = true;
            }
            const value: ?[]const u8 = if (secrets) |sc|
                try secret.resolver.resolveCached(arena, io, sc.env, sc.cache, s.uri)
            else
                null;
            const start = out.items.len;
            if (value) |v| {
                try out.appendSlice(arena, v);
                if (v.len == 0 or v[v.len - 1] != '\n') {
                    try out.append(arena, '\n');
                }
            } else {
                try out.appendSlice(arena, "<SECRET:");
                try out.appendSlice(arena, s.uri);
                try out.append(arena, '>');
                try out.append(arena, '\n');
            }
            try em.markSince(start, .secret);
        },
    }
}

const RecordMap = std.StringHashMap(data_mod.value.Value);
const ForLoop = @FieldType(dsl.ast.Directive.Kind, "for_loop");

fn parseNestBody(arena: std.mem.Allocator, src: []const u8, marker: []const u8, in_loop: bool) !dsl.ast.ParsedFile {
    return if (in_loop)
        dsl.driver.parseFileInLoop(arena, src, marker, null)
    else
        dsl.driver.parseFile(arena, src, marker, null);
}

/// Strip the loop-body comment prefix from every line of `body`, rejoining with
/// `\n`. A commented body (`#   abbr ...`) becomes its uncommented content; an
/// already-uncommented body passes through unchanged.
fn stripBody(arena: std.mem.Allocator, body: []const u8, marker: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, dsl.driver.stripLoopBodyPrefix(line, marker));
    }
    return out.toOwnedSlice(arena);
}

/// Evaluate a row predicate (a `where` filter or an in-loop `when` gate),
/// mapping an unknown loop-variable reference onto the compose diagnostic sink.
fn evalRow(
    arena: std.mem.Allocator,
    expr: *const dsl.ast.RowExpr,
    scope: []const interp.Frame,
    bindings: *const std.StringHashMap([]const u8),
    diag: ?*interp.Diag,
) EmitError!bool {
    var unknown: []const u8 = "";
    return dsl.row_expr.evaluate(arena, expr, scope, bindings, &unknown) catch |e| switch (e) {
        error.UnknownLoopVariable => {
            if (diag) |d| d.set(unknown);
            return error.UnknownLoopVariable;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// A scope-relative loop over `<var> in <outer>.<field>`, where `<outer>` names
/// an enclosing loop record: `.value` is that field, `.absent_field` when the
/// enclosing record lacks it (a typo, distinct from a present-but-empty array),
/// `.not_ref` when `<data>` is an ordinary file source (its head names no frame).
const FieldRef = union(enum) { not_ref, absent_field: []const u8, value: data_mod.value.Value };

fn loopFieldRef(scope: []const interp.Frame, data_source: []const u8) FieldRef {
    if (std.mem.indexOfScalar(u8, data_source, '/') != null) return .not_ref;
    const dot = std.mem.indexOfScalar(u8, data_source, '.') orelse return .not_ref;
    const head = data_source[0..dot];
    const field = data_source[dot + 1 ..];
    for (scope) |frame| {
        if (!std.mem.eql(u8, frame.name, head)) continue;
        return switch (frame.value) {
            .record => |r| if (r.get(field)) |v| .{ .value = v } else .{ .absent_field = field },
            .scalar => .not_ref,
        };
    }
    return .not_ref;
}

/// The elements an array-element loop iterates: an array's members, or a scalar
/// as a one-element list.
fn fieldAsScalars(arena: std.mem.Allocator, v: data_mod.value.Value) ![]const []const u8 {
    return switch (v) {
        .array_of_strings => |arr| arr,
        .string => |s| blk: {
            const one = try arena.alloc([]const u8, 1);
            one[0] = s;
            break :blk one;
        },
        .int, .bool => blk: {
            const one = try arena.alloc([]const u8, 1);
            one[0] = try v.format(arena);
            break :blk one;
        },
    };
}

/// Prepend a fresh (placeholder) frame for `name` onto `outer`, innermost first.
/// The caller sets `[0]` per row; the backing array is reused across iterations.
fn prependFrame(arena: std.mem.Allocator, outer: []const interp.Frame, name: []const u8) ![]interp.Frame {
    const s = try arena.alloc(interp.Frame, outer.len + 1);
    @memcpy(s[1..], outer);
    s[0] = .{ .name = name, .value = .{ .scalar = "" } };
    return s;
}

/// Emit a `for` directive: file/record loop, or a scope-relative array-element
/// loop. A loop body is itself a template -- re-parsed once (not per row) and,
/// when it carries nested directives, walked recursively per row.
fn emitForLoop(
    arena: std.mem.Allocator,
    io: Io,
    em: *Emitter,
    file: ManagedFile,
    loop: ForLoop,
    bindings: *const std.StringHashMap([]const u8),
    ctx: interp.Ctx,
    secrets: ?SecretCtx,
    nest: Nest,
) EmitError!void {
    if (nest.depth > max_nest_depth) return error.RecursionTooDeep;

    // A GENERATOR loop (`for ... into`) never composes inline: it is intercepted
    // by `composeGenerator` as a file's sole top-level directive. Reaching here
    // means it shares the file with other content -- a misuse, not a silent
    // single-file emission.
    if (loop.into != null) return error.IntoOnNonGenerator;

    // Loop-level `when` filter (axis grammar, machine-gated): suppress the loop.
    if (loop.when) |expr_ptr| {
        if (!dsl.axis.evaluate(expr_ptr, bindings)) return;
    }

    // Re-parse the body ONCE. Inside it a standalone `when` is a row gate.
    const parsed_body = try parseNestBody(arena, loop.body_template, nest.marker, true);
    const nested = parsed_body.directives.len > 0;

    const scope = try prependFrame(arena, ctx.scope, loop.variable);
    var ctx2 = ctx;
    ctx2.scope = scope;

    // Body stripped once for the fast (non-nested) path; unused when nested.
    const stripped = if (!nested) try stripBody(arena, loop.body_template, nest.marker) else "";
    if (!nested) try interp.lint(arena, stripped);

    // `for url in id.match_urls`: iterate an enclosing record's array field.
    switch (loopFieldRef(ctx.scope, loop.data_source)) {
        .not_ref => {},
        .absent_field => |f| {
            // The enclosing record lacks the named field: a typo, not zero rows
            // (a present-but-empty array reaches `.value` and yields no rows).
            if (ctx.diag) |dg| dg.set(f);
            return error.LoopSourceFieldNotFound;
        },
        .value => |v| {
            const scalars = try fieldAsScalars(arena, v);
            // A `where` here filters on the enclosing scope (unchanged per
            // element), so evaluate it once.
            if (loop.where) |w| {
                if (!try evalRow(arena, w, ctx.scope, bindings, ctx.diag)) return;
            }
            for (scalars) |elem| {
                scope[0] = .{ .name = loop.variable, .value = .{ .scalar = elem } };
                if (nested) {
                    const inner: Nest = .{ .marker = nest.marker, .record = nest.record, .in_for = true, .depth = nest.depth + 1 };
                    try emitParsedBody(arena, io, em, file, bindings, ctx2, secrets, loop.body_template, parsed_body, inner);
                } else {
                    try emitSecretAwareBody(em, arena, stripped, ctx2, true, nest.record, .always_add, .{ .flat = overlayOrigin(file) });
                }
            }
            return;
        },
    }

    // File-based data source: a path with `/` is repo-relative (private layer
    // shadows repo); a bare name is per-file (`<file>.d/<name>`).
    const data_path = blk: {
        if (std.mem.indexOfScalar(u8, loop.data_source, '/') != null) {
            if (file.private_dir.len > 0) {
                const priv = try source.path.joinKeyOnto(arena, file.private_dir, loop.data_source);
                if (fileExists(io, priv)) break :blk priv;
            }
            if (file.repo_dir.len == 0) return error.NoRepoRootForSharedData;
            break :blk try source.path.joinKeyOnto(arena, file.repo_dir, loop.data_source);
        }
        const overlay_dir = try std.fmt.allocPrint(arena, "{s}.d", .{file.source_base_abs});
        break :blk try source.path.joinKeyOnto(arena, overlay_dir, loop.data_source);
    };

    const arr_map = data_mod.source.loadFile(arena, io, data_path) catch |e| switch (e) {
        // Name the data source instead of a bare FileNotFound, so a typo'd
        // `for x in ...` points at the path.
        error.FileNotFound => {
            if (ctx.diag) |dg| dg.set(data_path);
            return error.DataSourceNotFound;
        },
        else => return e,
    };
    const stem = filenameStem(loop.data_source);
    const records = arr_map.get(stem) orelse {
        if (ctx.diag) |dg| dg.set(data_path);
        return error.DataSourceArrayNotFound;
    };

    // Per-row `where` skips non-matching records. A row expands its template
    // UNCONDITIONALLY (a row always carries a record, so `<entry.X>` resolves
    // even with a null machine). Each row is attributed to its data-source row
    // so commit can reverse-parse an edit back into it -- but only a TOP-LEVEL
    // loop; a NESTED loop's rows go to the overlay (manual), since a
    // recursively-composed line cannot be reverse-parsed to one data row.
    for (records, 0..) |*record_ptr, row_idx| {
        scope[0] = .{ .name = loop.variable, .value = .{ .record = record_ptr } };
        // Set the row frame first so a `where` can reference the loop variable
        // (and any enclosing frame) by name.
        if (loop.where) |w| {
            if (!try evalRow(arena, w, scope, bindings, ctx.diag)) continue;
        }
        if (nested) {
            const inner: Nest = .{ .marker = nest.marker, .record = record_ptr, .in_for = true, .depth = nest.depth + 1 };
            try emitParsedBody(arena, io, em, file, bindings, ctx2, secrets, loop.body_template, parsed_body, inner);
        } else {
            const origin: Origin = if (nest.in_for)
                overlayOrigin(file)
            else
                .{ .loop = .{ .data_source = data_path, .row = @intCast(row_idx), .template = stripped } };
            try emitSecretAwareBody(em, arena, stripped, ctx2, true, record_ptr, .always_add, .{ .flat = origin });
        }
    }
}

/// Walk a pre-parsed region body, emitting content lines and recursing into
/// nested directives. Used only for bodies that contain nested directives; a
/// flat body is emitted whole by its directive arm.
fn emitParsedBody(
    arena: std.mem.Allocator,
    io: Io,
    em: *Emitter,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    ctx: interp.Ctx,
    secrets: ?SecretCtx,
    src: []const u8,
    parsed: dsl.ast.ParsedFile,
    nest: Nest,
) EmitError!void {
    if (nest.depth > max_nest_depth) return error.RecursionTooDeep;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: u32 = 0;
    var dir_idx: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (dir_idx < parsed.directives.len) {
            const d = parsed.directives[dir_idx];
            if (line_no >= d.start_line and line_no <= d.end_line) {
                if (line_no == d.start_line) {
                    try emitDirective(arena, io, em, file, d, bindings, ctx, secrets, nest);
                }
                if (line_no == d.end_line) dir_idx += 1;
                continue;
            }
        }
        try emitContentLine(arena, em, file, line, ctx, nest);
    }
}

/// Emit one content line of a nested region body. Inside a loop it is
/// prefix-stripped and interpolated unconditionally against the scope;
/// otherwise (a nested directive inside a top-level `when`) it matches the flat
/// when-gate path (no strip, machine-gated interp, no record). Either way an
/// inline secret marks only this line `.secret`.
fn emitContentLine(
    arena: std.mem.Allocator,
    em: *Emitter,
    file: ManagedFile,
    line: []const u8,
    ctx: interp.Ctx,
    nest: Nest,
) EmitError!void {
    const text = if (nest.in_for) dsl.driver.stripLoopBodyPrefix(line, nest.marker) else line;
    try interp.lint(arena, text);
    const rec: ?*const RecordMap = if (nest.in_for) nest.record else null;
    const interp_on = nest.in_for or ctx.machine != null;
    try emitSecretAwareBody(em, arena, text, ctx, interp_on, rec, .always_add, .{ .flat = overlayOrigin(file) });
}

/// Emit a directive's literal fallback body (verbatim base text plus a
/// trailing newline), attributed to the whole-base overlay origin.
fn emitLiteralBody(arena: std.mem.Allocator, em: *Emitter, file: ManagedFile, body: []const u8, ctx: interp.Ctx) !void {
    // A directive fallback body interpolates `<machine.X>`/`<env.X>`/`<data.X>`/
    // `<secret:URI>` captures like a `when` body does; otherwise the literal
    // `<...>` reaches the live file. overlayOrigin keeps the span manual, so
    // commit never bakes the expanded value back into source; a resolved inline
    // secret makes only its own line `.secret` so its cleartext stays out of the
    // cache without redacting the body's other lines.
    try emitSecretAwareBody(em, arena, body, ctx, ctx.machine != null, null, .always_add, .{ .flat = overlayOrigin(file) });
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn emitFragmentByPath(
    arena: std.mem.Allocator,
    io: Io,
    em: *Emitter,
    file: ManagedFile,
    rel_path: []const u8,
    ctx: interp.Ctx,
) !void {
    const overlay_dir = try std.fmt.allocPrint(arena, "{s}.d", .{file.source_base_abs});
    const fragment_abs = try source.path.joinKeyOnto(arena, overlay_dir, rel_path);
    const content = Io.Dir.cwd().readFileAlloc(io, fragment_abs, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        // Name the missing fragment instead of surfacing a bare FileNotFound, so
        // a typo'd `include "..."` points the user at the path it looked for.
        error.FileNotFound => {
            if (ctx.diag) |d| d.set(rel_path);
            return error.IncludeFragmentNotFound;
        },
        else => return e,
    };
    const lang = langFromPath(rel_path);
    const stripped = pacifier.strip(content, lang);
    try emitSecretAwareBody(em, arena, stripped.text, ctx, ctx.machine != null, null, .single, .{
        .fragment = .{ .file = file, .path = fragment_abs, .first_line = stripped.lines + 1 },
    });
}

/// Append `bytes` to `out`, ensuring the output ends with a newline so the
/// next emission doesn't glue onto fragment content that lacked one.
fn appendWithTrailingNewline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    try out.appendSlice(arena, bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
        try out.append(arena, '\n');
    }
}

const PickedFragment = struct {
    /// Unexpanded (pacifier-stripped) fragment text; the caller expands it per
    /// line via `emitSecretAwareBody` so an inline secret marks only its line.
    text: []const u8,
    path: []const u8,
    /// 1-based source line the first emitted line came from (2 when a pacifier
    /// line was stripped).
    first_line: u32,
};

fn pickFragmentFromRegion(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    dir_name: []const u8,
    bindings: *const std.StringHashMap([]const u8),
) !?PickedFragment {
    for (file.regions) |region| {
        if (!std.mem.eql(u8, region.name, dir_name)) continue;

        const idx = try pickFragmentIndex(arena, region.fragments, bindings) orelse return null;
        const frag_path = region.fragments[idx].path;
        const content = try Io.Dir.cwd().readFileAlloc(io, frag_path, arena, .limited(max_file_bytes));
        const lang = langFromPath(frag_path);
        const stripped = pacifier.strip(content, lang);
        return .{ .text = stripped.text, .path = frag_path, .first_line = stripped.lines + 1 };
    }
    return null;
}

/// Index of the fragment `bindings` selects from a region, or null when none
/// matches.
///
/// A fragment named EXACTLY for the axis value wins over one that has to have a
/// suffix stripped to reach it: an axis value may itself contain a dot, so
/// `.d/machine/host.local` stands for `machine=host.local` and only falls back
/// to `machine=host` if no fragment is named for the binding outright.
fn pickFragmentIndex(
    arena: std.mem.Allocator,
    fragments: []const Fragment,
    bindings: *const std.StringHashMap([]const u8),
) !?usize {
    for (fragments, 0..) |frag, i| {
        const t = frag.exact_tuple orelse continue;
        if (match_mod.matches(t, bindings)) return i;
    }
    var tuples: std.ArrayList(AxisTuple) = .empty;
    defer tuples.deinit(arena);
    for (fragments) |frag| try tuples.append(arena, frag.tuple);
    return match_mod.bestMatch(tuples.items, bindings);
}

/// Choose the identifier passed to `comment.markerForExtension`.
///
/// `markerForExtension` matches whole strings against a table that contains
/// extensions (`.lua`), full dotfile names (`.zshrc`), and un-dotted
/// basenames (`Dockerfile`).
fn identForMarker(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return basename;

    // Dotfile with no further dot: the basename IS the identifier.
    if (basename[0] == '.') {
        const rest = basename[1..];
        if (std.mem.indexOfScalar(u8, rest, '.') == null) return basename;
    }

    // Un-dotted basename (e.g. `Dockerfile`): return it directly so the marker
    // table lookup succeeds.
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[dot..];
}

/// The comment marker for a source file, or null when no signal is available.
/// Tries the extension, then a shebang (extensionless scripts), then an
/// apparent `# mox:` directive (plain config files with no extension/shebang).
fn markerForFile(source_base_path: []const u8, base_content: []const u8) ?[]const u8 {
    const ident = identForMarker(source_base_path);
    if (dsl.comment.markerForExtension(ident)) |m| return m;
    if (markerForShebang(base_content)) |m| return m;
    if (markerFromApparentDirective(base_content)) |m| return m;
    return null;
}

/// Stem of a filename: the basename without its trailing extension.
/// Handles paths (returns the last segment's stem, ignoring directories).
fn filenameStem(filename: []const u8) []const u8 {
    const basename = std.fs.path.basename(filename);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[0..dot];
}

/// Infer the comment marker from a shebang on line 1, if any. The
/// interpreter name (last path segment) is mapped to its known marker.
/// Returns null when there is no shebang or the interpreter is unrecognized.
fn markerForShebang(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "#!")) return null;
    const eol = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[2..eol];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    // Take the last path component of the interpreter (skip `env <name>`).
    const first_word_end = std.mem.indexOfAnyPos(u8, trimmed, 0, " \t") orelse trimmed.len;
    const interp_path = trimmed[0..first_word_end];
    const last_slash = std.mem.lastIndexOfScalar(u8, interp_path, '/');
    var interp_name: []const u8 = if (last_slash) |s| interp_path[s + 1 ..] else interp_path;
    // `#!/usr/bin/env <name>` or `#!/usr/bin/env -S <name>` — pick the next word.
    if (std.mem.eql(u8, interp_name, "env")) {
        const rest = std.mem.trimStart(u8, trimmed[first_word_end..], " \t");
        var skip: usize = 0;
        if (std.mem.startsWith(u8, rest, "-S")) {
            const after = std.mem.trimStart(u8, rest[2..], " \t");
            skip = @intFromPtr(after.ptr) - @intFromPtr(rest.ptr);
        }
        const after_skip = rest[skip..];
        const word_end = std.mem.indexOfAnyPos(u8, after_skip, 0, " \t") orelse after_skip.len;
        interp_name = after_skip[0..word_end];
    }
    if (interp_name.len == 0) return null;
    if (eqAny(interp_name, &.{
        // POSIX shells + common alternatives
        "bash",   "sh",      "zsh",     "fish",   "ksh",     "ash",
        "dash",   "mksh",    "yash",    "elvish", "xonsh",   "nushell",
        "nu",     "pwsh",    "rc",
        // Scripting languages with `#` line comments
             "python", "python3", "ruby",
        "perl",   "perl5",   "perl6",   "raku",   "tcl",     "tclsh",
        "node",   "deno",    "bun",     "lua",    "luajit",  "guile",
        "scheme", "racket",  "chicken", "csi",    "gosh",    "expect",
        "wish",
        // Text/data processors
          "awk",     "gawk",    "mawk",   "sed",     "jq",
        "yq",
        // Statistical / scientific
            "Rscript", "julia",   "octave",
    })) return "#";
    return null;
}

fn eqAny(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}

/// If `content` has any line of the form `<ws><1-3 non-alnum chars><ws>mox:`,
/// return the marker chars (the comment-prefix preceding `mox:`). Otherwise
/// null. Used to infer the comment marker for files whose extension isn't in
/// the marker table — `# mox: ...` is itself proof that `#` is the marker.
fn markerFromApparentDirective(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var rest = std.mem.trimStart(u8, line, " \t");
        if (rest.len == 0 or std.ascii.isAlphanumeric(rest[0])) continue;
        var i: usize = 0;
        while (i < @min(@as(usize, 3), rest.len) and
            !std.ascii.isAlphanumeric(rest[i]) and
            rest[i] != ' ' and rest[i] != '\t') : (i += 1)
        {}
        if (i == 0) continue;
        const candidate_marker = rest[0..i];
        const after = std.mem.trimStart(u8, rest[i..], " \t");
        if (std.mem.startsWith(u8, after, "mox:")) return candidate_marker;
    }
    return null;
}

fn langFromPath(path: []const u8) []const u8 {
    const ident = identForMarker(path);
    if (std.mem.eql(u8, ident, ".lua")) return "lua";
    if (std.mem.eql(u8, ident, ".ts")) return "ts";
    if (std.mem.eql(u8, ident, ".tsx")) return "ts";
    if (std.mem.eql(u8, ident, ".js")) return "js";
    if (std.mem.eql(u8, ident, ".jsx")) return "js";
    if (std.mem.eql(u8, ident, ".py")) return "python";
    if (std.mem.eql(u8, ident, ".sh")) return "shell";
    if (std.mem.eql(u8, ident, ".bash")) return "shell";
    if (std.mem.eql(u8, ident, ".zsh")) return "shell";
    if (std.mem.eql(u8, ident, ".zshrc")) return "shell";
    if (std.mem.eql(u8, ident, ".bashrc")) return "shell";
    if (std.mem.eql(u8, ident, ".profile")) return "shell";
    return "shell";
}
