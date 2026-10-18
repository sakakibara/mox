const std = @import("std");
const toml = @import("toml");
const json = @import("json");
const yaml = @import("yaml");
const source = @import("../source/root.zig");
const machine = @import("../machine/root.zig");
const match_mod = @import("match.zig");
const toml_merge = @import("toml_merge.zig");
const json_merge = @import("json_merge.zig");
const yaml_merge = @import("yaml_merge.zig");

/// A filesystem path rendered in key form (`/`-separated) for a user-facing
/// diagnostic, so a source file is named the same way on every platform.
fn keyPath(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (std.fs.path.sep == '/') return path;
    const dup = arena.dupe(u8, path) catch return path;
    std.mem.replaceScalar(u8, dup, std.fs.path.sep, '/');
    return dup;
}
const ini_merge = @import("ini_merge.zig");
const interp = @import("interp.zig");
const context = @import("context/root.zig");
const json_interp = @import("json_interp.zig");
const validate = @import("validate.zig");
const catB = @import("catB.zig");
const dsl = @import("../dsl/root.zig");
const prov_mod = @import("../provenance/root.zig");

const Io = std.Io;
const ManagedFile = source.tree.ManagedFile;
const AxisTuple = source.tree.AxisTuple;
const Segment = prov_mod.map.Segment;

pub const ComposeError = error{
    /// No base and no overlay matches the active bindings.
    NoBaseOrMatchingOverlay,
    /// A layer of a structurally merged source carries an inline `mox:`
    /// directive. Inline directives are the single-layer mechanism; overlays
    /// are the multi-layer one. In a structural merge a directive line is only
    /// a comment (parsed and dropped, or emitted as text), so a region's body
    /// would land unconditionally and a `secret` or `default` would vanish --
    /// silently, and in the unsafe direction. The diag names the layer and
    /// the line.
    InlineDirectiveWithOverlay,
};

const max_layer_bytes: usize = 4 * 1024 * 1024;

/// Compose a Category A managed file: TOML, JSON and YAML deep-merge;
/// gitconfig and INI section-merge.
///
/// Every layer is parsed in the target's format and dialect first, and the
/// composed output after capture expansion: a failure is
/// `error.FormatViolation`, `diag` naming where and why.
///
/// Cat A owns its own provenance. A single-layer file carrying `# mox:`
/// directives routes through Cat B, whose per-line segments (including
/// `.secret` for a resolved secret) flow straight into `prov`. Every other
/// route (structural merge, verbatim pass-through) is one whole-file segment,
/// `.secret` when interpolation resolved an inline `<secret:URI>` so its
/// cleartext is kept out of the content cache and snapshots. `diag`, if
/// set, names the failing capture on a resolution error.
pub fn compose(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov_opt: ?*std.ArrayList(Segment),
    diag_opt: ?*interp.Diag,
) !?[]u8 {
    const format = file.format orelse return error.NoBaseOrMatchingOverlay;
    // Provenance names the secret lines a parse error must not quote, and
    // the diag whether a key capture expanded.
    var local_prov: std.ArrayList(Segment) = .empty;
    const prov = prov_opt orelse &local_prov;
    var local_diag: interp.Diag = .{};
    const diag = diag_opt orelse &local_diag;
    var run: Run = .{};
    const out = (try switch (format) {
        .toml => composeToml(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, &run),
        .gitconfig => composeSectionMerge(arena, io, file, bindings, machine_state_opt, secrets, .gitconfig, prov, diag, &run),
        .yaml => composeYaml(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, &run),
        .json, .jsonc => composeJson(arena, io, file, format, bindings, machine_state_opt, secrets, prov, diag, &run),
        .ini => composeSectionMerge(arena, io, file, bindings, machine_state_opt, secrets, .generic, prov, diag, &run),
    }) orelse return null;
    if (machine_state_opt != null) try checkComposed(arena, file, format, out, run, prov.items, secrets, diag);
    return out;
}

/// What one composition used, for the output check.
const Run = struct {
    /// Display names of the layers that composed.
    layers: []const []const u8 = &.{},
};

/// Parse the composed output in its format. Exempt: an empty partial render
/// ("mox owns nothing here"), and output off the resolving path still holding
/// a secret placeholder, whose value is unknown there.
fn checkComposed(
    arena: std.mem.Allocator,
    file: ManagedFile,
    format: source.format.Format,
    out: []const u8,
    run: Run,
    segments: []const Segment,
    secrets: ?catB.SecretCtx,
    diag: *interp.Diag,
) !void {
    if (file.ownership != .none and std.mem.trim(u8, out, " \t\r\n").len == 0) return;
    if (secrets == null and std.mem.indexOf(u8, out, "<SECRET:") != null) return;
    // A resolved secret anywhere in the output keeps every byte of the
    // parser's message out of the report: a message can quote any line.
    const has_secret = for (segments) |seg| {
        if (seg.origin == .secret) break true;
    } else false;
    try validate.checkOutput(arena, format, out, run.layers, has_secret, diag);
    if (format.isJson() and (run.layers.len > 1 or diag.json_key_capture)) {
        try validate.checkDuplicateKeys(arena, format, out, "", run.layers, has_secret, diag);
    }
}

/// A layer path as a diagnostic names it: relative to the repo (or to the
/// private layer's parent), in key form.
pub fn layerDisplay(arena: std.mem.Allocator, file: ManagedFile, path: []const u8) []const u8 {
    const private_parent = if (file.private_dir.len > 0) std.fs.path.dirname(file.private_dir) orelse "" else "";
    const roots = [_][]const u8{ file.repo_dir, private_parent };
    for (roots) |root| {
        if (root.len == 0) continue;
        if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len])) {
            return keyPath(arena, path[root.len + 1 ..]);
        }
    }
    return keyPath(arena, path);
}

fn displayAll(arena: std.mem.Allocator, file: ManagedFile, paths: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, out) |p, *o| o.* = layerDisplay(arena, file, p);
    return out;
}

/// A base layer after the single leading-block pass: head directives parsed
/// once, consumed lines stripped, whole-file gate evaluated.
const Head = struct {
    /// Base text with the ownership and check lines removed. A whole-file gate
    /// line is NOT one of them: it stays, so the text handed to Cat B still
    /// carries the gate that scopes the rest of the file.
    text: []const u8,
    /// `text` with a whole-file gate's own line removed too: the gate's body,
    /// which is what the structural routes compose. Equal to `text` when the
    /// file has no whole-file gate.
    body: []const u8,
    /// The source lines `text` and `body` respectively leave out, ascending,
    /// so provenance can name the lines the source file actually has.
    text_removed: []const u32 = &.{},
    body_removed: []const u32 = &.{},
    /// A leading whole-file gate evaluated false: the file is absent on this
    /// machine.
    absent: bool = false,
    /// The file declares `own`/`disown`: mox owns only part of a file a program
    /// also writes. Such a file is patched, never materialized or omitted
    /// wholesale, so an empty render is "mox owns nothing here", not "no file".
    partial: bool = false,
};

/// Read the base layer and run the ONE leading-block pass: parse the head
/// once (ownership declarations, check argv, whole-file gate candidate),
/// strip the consumed lines, and evaluate the gate. An overlay seed
/// (`has_base == false`) is returned verbatim: a leading `mox:` line there
/// is inert content, and a gate belongs on a base file. Head recognition
/// runs on the same `max_head_bytes` prefix the walk reads, so walk and
/// compose classify a file identically by construction. Strict JSON has no
/// head: the walk reads its directives from its attributes.
fn readBaseHead(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    path: []const u8,
    marker_opt: ?[]const u8,
    bindings: *const dsl.resolver.Resolver,
) !Head {
    const read = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    // A capture in a JSON string is one unit, its quotes included.
    const raw = if (file.format != null and file.format.?.isJson()) try json_interp.escapeCaptureQuotes(arena, read) else read;
    if (marker_opt == null or !file.has_base) return .{ .text = raw, .body = raw, .partial = file.ownership != .none };
    const marker = marker_opt.?;
    const head_text = raw[0..@min(raw.len, source.tree.max_head_bytes)];
    const parsed = source.head.parse(arena, head_text, marker) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // The walk has already refused a malformed head; keep the text
        // intact so the failure surfaces with a source location downstream.
        else => return .{ .text = raw, .body = raw },
    };
    const partial = parsed.ownership != .none;
    const stripped = if (parsed.spans.len == 0) raw else try source.head.stripSpans(arena, raw, parsed.spans);
    const removed = try source.head.removedLines(arena, raw, parsed.spans);
    const whole: Head = .{ .text = stripped, .body = stripped, .text_removed = removed, .body_removed = removed, .partial = partial };
    if (parsed.gate == null) return whole;
    // The candidate is a whole-file existence gate only when the DSL agrees:
    // the file must parse, and the gate must run to EOF (a matching `end`
    // later makes it a region, composed through Cat B).
    const expr = wholeFileGateExpr(arena, stripped, marker) orelse return whole;
    // The gate line is line 1 of the stripped text by construction; consume
    // exactly it. A gate evaluating false leaves `body` the same way, so the
    // layered-directive scan sees the same text on every machine.
    const nl = std.mem.indexOfScalar(u8, stripped, '\n');
    return .{
        .text = stripped,
        .body = if (nl) |n| stripped[n + 1 ..] else "",
        .text_removed = removed,
        .body_removed = try source.head.withRemovedLine(arena, removed, source.head.sourceLine(removed, 1)),
        .absent = !dsl.axis.evaluate(expr, bindings),
        .partial = partial,
    };
}

const Prepared = struct { layers: []const []const u8, hd: Head };

/// `collectMatchingLayers` + `readBaseHead` + the layered-directive refusal
/// and the layer checks, in the one order that keeps every refusal a fact
/// about the repo: every machine runs them, whatever its own gate and
/// overlay matches then decide. Null when the file does not materialize
/// here.
fn prepare(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    format: source.format.Format,
    bindings: *const dsl.resolver.Resolver,
    diag: ?*interp.Diag,
    run: *Run,
) !?Prepared {
    const marker = format.marker();
    const layers = try collectMatchingLayers(arena, file, bindings);
    var hd: Head = if (layers.len == 0)
        .{ .text = "", .body = "" }
    else
        try readBaseHead(arena, io, file, layers[0], marker, bindings);
    if (marker) |m| {
        if (file.overlays.len > 0) try refuseRegionInLayers(arena, io, file, hd.body, m, diag);
    }
    try checkLayers(arena, io, file, format, if (file.has_base) hd else null, layers.len > 1, bindings, diag);
    if (file.gate) |g| {
        const expr = try dsl.axis.parseString(arena, g);
        if (!dsl.axis.evaluate(expr, bindings)) hd.absent = true;
    }
    if (layers.len == 0 or hd.absent) return null;
    run.layers = try displayAll(arena, file, layers);
    return .{ .layers = layers, .hd = hd };
}

/// Parse every layer as written, matching this machine or not: the base
/// after its head pass, and each overlay. A layer that is no document of
/// its format until composed is checked through the output instead: a
/// non-JSON layer holding a capture (`port = <data.u.port>`) or a region (its
/// alternates may repeat a key), and a JSONC base composed through Cat B.
/// In a JSON merge each matching layer must also hold no duplicate key,
/// which its parse would drop.
fn checkLayers(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    format: source.format.Format,
    base: ?Head,
    merging: bool,
    bindings: *const dsl.resolver.Resolver,
    diag: ?*interp.Diag,
) !void {
    if (base) |hd| {
        const display = layerDisplay(arena, file, file.source_base_abs);
        const skip = switch (format) {
            .json => false,
            .jsonc => containsMoxDirectiveJson(hd.body),
            else => containsMoxDirective(hd.body) or interp.containsCapture(hd.body),
        };
        if (!skip) {
            try validate.checkLayer(arena, format, hd.body, display, targetKey(file), hd.body_removed, diag);
            if (format.isJson() and merging) try validate.checkDuplicateKeys(arena, format, hd.body, display, &.{}, false, diag);
        }
    }
    for (file.overlays) |o| {
        const raw = Io.Dir.cwd().readFileAlloc(io, o.path, arena, .limited(max_layer_bytes)) catch |e| {
            if (diag) |d| d.set(try std.fmt.allocPrint(arena, "{s}: could not be read: {s}", .{ keyPath(arena, o.path), @errorName(e) }));
            return e;
        };
        if (!format.isJson() and interp.containsCapture(raw)) continue;
        const display = layerDisplay(arena, file, o.path);
        try validate.checkLayer(arena, format, if (format.isJson()) try json_interp.escapeCaptureQuotes(arena, raw) else raw, display, targetKey(file), &.{}, diag);
        if (format.isJson() and merging and match_mod.matches(match_mod.effectiveOverlayTuple(o, bindings), bindings)) {
            try validate.checkDuplicateKeys(arena, format, raw, display, &.{}, false, diag);
        }
    }
}

fn composeToml(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
    run: *Run,
) !?[]u8 {
    const prep = (try prepare(arena, io, file, file.format.?, bindings, diag, run)) orelse return null;
    const layers = prep.layers;
    const hd = prep.hd;

    // Single-layer base with `# mox:` content directives routes through Cat B for
    // include / from / when. A whole-file gate alone composes its body
    // structurally; a gate with further directives under it goes to Cat B WITH
    // its gate line, so the gate scopes the body there exactly as it does in a
    // Cat B file. The pass-through preserves comments, blank lines, and key
    // ordering.
    if (layers.len == 1) {
        if (containsMoxDirective(hd.body)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text, hd.text_removed, !hd.partial);
        return interpolate(arena, io, file, hd.body, hd.body_removed, machine_state_opt, secrets, prov, diag);
    }

    // Multi-layer merge seeds from the head-processed base text, so no
    // consumed directive line reaches the parser.
    const base = try expandLayer(arena, io, file, file.source_base_abs, hd.body, hd.body_removed, machine_state_opt, secrets, diag);
    var secret = base.secret;
    var merged: toml.Value = toml.parse(arena, base.text, .{}) catch |e| return layerFailed(arena, e, .toml, base, diag);
    for (layers[1..]) |path| {
        const layer = try readLayer(arena, io, file, path, machine_state_opt, secrets, diag);
        secret = secret or layer.secret;
        const next = toml.parse(arena, layer.text, .{}) catch |e| return layerFailed(arena, e, .toml, layer, diag);
        merged = try toml_merge.mergeTables(arena, merged, next);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try toml.encode(&aw.writer, merged, .{});
    return mergedOutput(arena, file, aw.written(), secret, prov);
}

/// Compose a JSON-family managed file. Mirrors `composeToml`: a single
/// layer passes through verbatim (a JSONC one through Cat B when it carries
/// `// mox:` directives); multiple layers deep-merge structurally, every
/// layer read in the target's dialect. Merged output is pretty-printed plain
/// JSON, so comments survive only the single-layer pass-through.
fn composeJson(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    format: source.format.Format,
    bindings: *const dsl.resolver.Resolver,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
    run: *Run,
) !?[]u8 {
    const prep = (try prepare(arena, io, file, format, bindings, diag, run)) orelse return null;
    const layers = prep.layers;
    const hd = prep.hd;
    const dialect = format.jsonDialect();

    if (layers.len == 1) {
        if (format == .jsonc and containsMoxDirectiveJson(hd.body)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text, hd.text_removed, !hd.partial);
        return interpolateJson(arena, io, file, dialect, false, hd.body, hd.body_removed, machine_state_opt, secrets, prov, diag);
    }

    var merged: json.Value = try json.parse(arena, hd.body, .{ .dialect = dialect });
    for (layers[1..]) |path| {
        const next = try parseJsonFile(arena, io, path, dialect);
        merged = try json_merge.deepMerge(arena, merged, next);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, merged, .{ .indent = 2 });
    // Target files end with a newline, matching the toml composer's output.
    try aw.writer.writeByte('\n');
    return interpolateJson(arena, io, file, dialect, true, aw.written(), &.{}, machine_state_opt, secrets, prov, diag);
}

/// Compose a `.yaml` / `.yml` managed file. Mirrors `composeJson`: single
/// layer passes through verbatim (Cat B if it carries `# mox:` directives;
/// YAML's comment marker is `#`); multiple layers deep-merge structurally.
/// Merged output is re-emitted block-style YAML, so comments survive only
/// the single-layer pass-through path.
fn composeYaml(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
    run: *Run,
) !?[]u8 {
    const prep = (try prepare(arena, io, file, file.format.?, bindings, diag, run)) orelse return null;
    const layers = prep.layers;
    const hd = prep.hd;

    if (layers.len == 1) {
        if (containsMoxDirective(hd.body)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text, hd.text_removed, !hd.partial);
        return interpolate(arena, io, file, hd.body, hd.body_removed, machine_state_opt, secrets, prov, diag);
    }

    // A directive-only base leaves no YAML document to parse, so the first
    // overlay seeds the merge.
    const base = try expandLayer(arena, io, file, file.source_base_abs, hd.body, hd.body_removed, machine_state_opt, secrets, diag);
    var secret = base.secret;
    const blank = std.mem.trim(u8, base.text, " \t\r\n").len == 0;
    var merged: ?yaml.Value = if (blank) null else yaml.parse(arena, base.text, .{}) catch |e| return layerFailed(arena, e, .yaml, base, diag);
    for (layers[1..]) |path| {
        const layer = try readLayer(arena, io, file, path, machine_state_opt, secrets, diag);
        secret = secret or layer.secret;
        const next = yaml.parse(arena, layer.text, .{}) catch |e| return layerFailed(arena, e, .yaml, layer, diag);
        merged = if (merged) |m| try yaml_merge.deepMerge(arena, m, next) else next;
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    // yaml.emit already terminates the document with a trailing newline,
    // matching the toml/json composers' single-newline output convention.
    try yaml.emit(&aw.writer, merged.?, .{});
    return mergedOutput(arena, file, aw.written(), secret, prov);
}

/// Compose a gitconfig or INI managed file via raw-line section-merge.
/// Mirrors `composeToml`: a single layer passes through verbatim (or
/// routes to Cat B when it carries `# mox:` directives); multiple layers
/// fold through `ini_merge.merge` in increasing specificity.
fn composeSectionMerge(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    dialect: ini_merge.Dialect,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
    run: *Run,
) !?[]u8 {
    const prep = (try prepare(arena, io, file, file.format.?, bindings, diag, run)) orelse return null;
    const layers = prep.layers;
    const hd = prep.hd;

    if (layers.len == 1) {
        if (containsMoxDirective(hd.body)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text, hd.text_removed, !hd.partial);
        return interpolate(arena, io, file, hd.body, hd.body_removed, machine_state_opt, secrets, prov, diag);
    }

    // Raw-line merge preserves comments, so the head-processed seed matters
    // here (the parse-then-emit formats would drop directive comments anyway).
    const base = try expandLayer(arena, io, file, file.source_base_abs, hd.body, hd.body_removed, machine_state_opt, secrets, diag);
    var secret = base.secret;
    var merged: []u8 = @constCast(base.text);
    for (layers[1..]) |path| {
        const layer = try readLayer(arena, io, file, path, machine_state_opt, secrets, diag);
        secret = secret or layer.secret;
        merged = try ini_merge.merge(arena, merged, layer.text, dialect);
    }
    return mergedOutput(arena, file, merged, secret, prov);
}

/// Heuristic: does `content` contain a `# mox: ...` line? Cheap substring
/// check is fine -- gitconfig comment marker is always `#`, and any false
/// positive (`mox:` appearing inside a value) at worst routes through Cat B
/// which would emit it unchanged anyway.
fn containsMoxDirective(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "# mox:") != null;
}

/// JSON/JSONC variant of `containsMoxDirective`: the comment marker is
/// `//`, so directives look like `// mox: ...`.
fn containsMoxDirectiveJson(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "// mox:") != null;
}

/// The first `mox:` directive line in `content`, as its 1-based line and
/// the line's text, or null. Every content directive counts: a region verb
/// would emit its body unconditionally in a merge, and a line directive
/// (`secret`, `default`, `include`, `keep-empty`) would be dropped as a
/// comment. Head directives are the head parser's and are skipped.
const DirectiveHit = struct { line: usize, text: []const u8 };
fn directiveLine(content: []const u8, marker: []const u8) ?DirectiveHit {
    var it = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, marker)) continue;
        const after = std.mem.trimStart(u8, t[marker.len..], " \t");
        if (!std.mem.startsWith(u8, after, "mox:")) continue;
        // A head directive is the walk's to recognise, inside its bounded
        // head; past that bound it is inert comment content by design.
        const verb = std.mem.trimStart(u8, after["mox:".len..], " \t");
        if (std.mem.startsWith(u8, verb, "own") or std.mem.startsWith(u8, verb, "disown") or std.mem.startsWith(u8, verb, "check")) continue;
        return .{ .line = n, .text = t };
    }
    return null;
}

/// The 1-based line of the first line whose trimmed text is `text`, in `raw`.
fn lineOf(raw: []const u8, text: []const u8) usize {
    var it = std.mem.splitScalar(u8, raw, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), text)) return n;
    }
    return 0;
}

/// A file with overlays is a structural merge, where a directive line is
/// only a comment: a region's body would emit unconditionally and a line
/// directive would vanish. Every layer is scanned, whether or not it
/// matches this machine, so the refusal is a fact about the repo and not
/// about who composes it: the base's gate body (so neither its head
/// directives nor its whole-file gate are mistaken for content), then each
/// overlay as written.
/// A hit names the layer and its line in the file as written.
fn refuseRegionInLayers(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    base_text: []const u8,
    marker: []const u8,
    diag: ?*interp.Diag,
) !void {
    if (file.has_base) {
        if (directiveLine(base_text, marker)) |hit| {
            const raw = try Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_layer_bytes));
            if (diag) |d| d.set(try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ keyPath(arena, file.source_base_abs), lineOf(raw, hit.text), hit.text }));
            return error.InlineDirectiveWithOverlay;
        }
    }
    for (file.overlays) |o| {
        const path = o.path;
        const raw = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes)) catch |e| {
            if (diag) |d| d.set(try std.fmt.allocPrint(arena, "{s}: could not be read: {s}", .{ keyPath(arena, path), @errorName(e) }));
            return e;
        };
        if (directiveLine(raw, marker)) |hit| {
            if (diag) |d| d.set(try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ keyPath(arena, path), hit.line, hit.text }));
            return error.InlineDirectiveWithOverlay;
        }
    }
}

/// The leading whole-file gate's parsed axis expression, or null when the
/// head's gate candidate does not gate the file: a `when` with no matching
/// `end` (gating to EOF) on line 1 conditions a structured file's existence
/// without turning it into Cat B text; anything else -- a parse failure
/// anywhere in the file, a terminated region, a missing expression -- is the
/// DSL's business.
fn wholeFileGateExpr(arena: std.mem.Allocator, content: []const u8, marker: []const u8) ?*const dsl.ast.AxisExpr {
    const parsed = dsl.driver.parseFile(arena, content, marker, null) catch return null;
    if (parsed.directives.len == 0) return null;
    const first = parsed.directives[0];
    if (first.kind != .when_gate or first.start_line > 1 or !first.kind.when_gate.to_eof) return null;
    return first.kind.when_gate.when;
}

/// Public, non-evaluating counterpart to `readBaseHead`'s gate detection: the
/// same head-parse-then-strip pass, without deciding whether the gate holds.
/// Used to advise on an out-of-vocabulary os=/arch= literal in the gate that
/// just skipped a file, without re-implementing detection. Null when `file`
/// has no base, its format is unrecognized, it cannot be read, or it has no
/// genuine whole-file gate.
pub fn wholeFileGateAxisExpr(arena: std.mem.Allocator, io: Io, file: ManagedFile) !?*const dsl.ast.AxisExpr {
    if (file.gate) |g| return dsl.axis.parseString(arena, g) catch null;
    if (!file.has_base or file.source_base_abs.len == 0) return null;
    const format = file.format orelse return null;
    const marker = format.marker() orelse return null;
    const raw = try Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_layer_bytes));
    const head_text = raw[0..@min(raw.len, source.tree.max_head_bytes)];
    const parsed = source.head.parse(arena, head_text, marker) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed.gate == null) return null;
    const stripped = if (parsed.spans.len == 0) raw else try source.head.stripSpans(arena, raw, parsed.spans);
    return wholeFileGateExpr(arena, stripped, marker);
}

/// Run the `<machine.X>` / `<data.X>` / `<secret:URI>` interpolation pass over a
/// single-layer Cat A source and record the file's whole-file provenance
/// segment. No machine state means no interp: the bytes pass through
/// unchanged, still attributed a whole-file segment. A resolved inline secret
/// makes its lines `.secret` so their cleartext stays out of the content
/// cache and snapshots.
fn interpolate(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bytes: []const u8,
    base_removed: []const u32,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    if (machine_state_opt == null) {
        try recordWhole(arena, prov, bytes, file, false, base_removed);
        return @constCast(bytes);
    }
    const ctx: interp.Ctx = .{
        .io = io,
        .machine = machine_state_opt,
        .repo_dir = file.repo_dir,
        .private_dir = file.private_dir,
        .secrets = if (secrets) |sc| .{ .env = sc.env, .cache = sc.cache } else null,
        .diag = diag,
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var enc = context.Encoder.init(context.kindFor(file.format, file.live_path, bytes), &out, secrets == null);
    var ectx = ctx;
    ectx.encoder = &enc;
    var lines_out: std.ArrayList(OutLine) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    var src_line: u32 = 0;
    while (lines.next()) |line| : (src_line += 1) {
        if (!first) try out.append(arena, '\n');
        first = false;
        const exp = try interp.expandTracked(arena, line, null, ectx);
        const kind: OutLine.Kind = if (exp.secret or exp.placeholder) .secret else if (!std.mem.eql(u8, exp.bytes, line)) .interpolated else .literal;
        // A value of several lines fills an output line for each of them.
        try lines_out.append(arena, .{ .kind = kind, .src_line = src_line, .out_lines = @intCast(std.mem.count(u8, exp.bytes, "\n") + 1) });
        try out.appendSlice(arena, exp.bytes);
    }
    try interp.finishEncoder(arena, &enc, out.items, file.live_path, diag);
    const result = try out.toOwnedSlice(arena);
    try recordInterpolated(arena, prov, result, file, false, lines_out.items, base_removed);
    return result;
}

/// `interpolate` for the JSON family: captures expand per string token
/// (`json_interp`), so a resolved value is escaped for JSON and bytes outside
/// a capture-bearing string are left as written.
fn interpolateJson(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    dialect: json.Dialect,
    merged: bool,
    bytes: []const u8,
    base_removed: []const u32,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    if (machine_state_opt == null) {
        try recordWhole(arena, prov, bytes, file, merged, base_removed);
        return @constCast(bytes);
    }
    const ctx: interp.Ctx = .{
        .io = io,
        .machine = machine_state_opt,
        .repo_dir = file.repo_dir,
        .private_dir = file.private_dir,
        .secrets = if (secrets) |sc| .{ .env = sc.env, .cache = sc.cache } else null,
        .diag = diag,
    };
    var state: json_interp.ScanState = .{ .dialect = dialect };
    const res = try json_interp.expand(arena, bytes, dialect, null, ctx, &state);
    if (res.secret) {
        try recordPerLineSecret(arena, prov, res.bytes, file, merged, res.line_secret, base_removed);
    } else {
        try recordWhole(arena, prov, res.bytes, file, merged, base_removed);
    }
    return res.bytes;
}

/// The non-secret origin a structural Cat A route attributes its output to:
/// `.base` when the output is the base passed through verbatim, `.overlay` when
/// layers actually merged (line-level attribution is out of scope for a
/// structural fold, so commit routes such a file by key path instead).
/// `merged` is whether more than one layer folded, not whether the file
/// DECLARES overlays: an overlay that does not match this machine contributes
/// nothing, and a file left composing verbatim from its base still routes by
/// line.
/// `base_removed` is the head pass's removed-line list for the composed text,
/// so a `.base` line names the source file as written.
fn nonSecretOrigin(file: ManagedFile, merged: bool, base_removed: []const u32, out_line: u32) prov_mod.map.Origin {
    return if (routesByLine(file, merged))
        .{ .base = .{ .line = source.head.sourceLine(base_removed, out_line + 1) } }
    else
        .{ .overlay = .{ .path = if (file.source_base_abs.len > 0) file.source_base_abs else file.source_base_path } };
}

fn routesByLine(file: ManagedFile, merged: bool) bool {
    return file.has_base and !merged;
}

/// Attribute the whole of `bytes` to `nonSecretOrigin` for a structural Cat A
/// route (merge or verbatim pass-through) that resolved no inline secret. An
/// interpolated file that does carry a secret goes through
/// `recordPerLineSecret` instead, so only its secret lines are `.secret`.
/// Appending line by line lets `map.append` coalesce a `.base` run, which
/// splits exactly where a stripped head line breaks the source numbering.
fn recordWhole(
    arena: std.mem.Allocator,
    prov: ?*std.ArrayList(Segment),
    bytes: []const u8,
    file: ManagedFile,
    merged: bool,
    base_removed: []const u32,
) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    if (!routesByLine(file, merged)) {
        try p.append(arena, .{ .out_start = 0, .out_len = n, .origin = nonSecretOrigin(file, merged, base_removed, 0) });
        return;
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try prov_mod.map.append(arena, p, i, 1, nonSecretOrigin(file, merged, base_removed, i));
    }
}

/// Attribute an interpolated structural file per line when it carries a secret:
/// only the lines that resolved one are `.secret`; the rest keep the file's
/// `nonSecretOrigin`. Marking the whole file `.secret` (as the old whole-file
/// record did on any secret) redacted its non-secret lines out of diffs and
/// snapshots and corrupted them on rollback. `line_secret[i]` is the flag for
/// output line `i`; a trailing empty line beyond `lineCount` is not attributed.
fn recordPerLineSecret(
    arena: std.mem.Allocator,
    prov: ?*std.ArrayList(Segment),
    bytes: []const u8,
    file: ManagedFile,
    merged: bool,
    line_secret: []const bool,
    base_removed: []const u32,
) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const is_secret = i < line_secret.len and line_secret[i];
        try prov_mod.map.append(arena, p, i, 1, if (is_secret) .secret else nonSecretOrigin(file, merged, base_removed, i));
    }
}

/// One source line of an interpolated file: what interpolation did to it,
/// which line of the composed source it is, and how many output lines it
/// filled.
const OutLine = struct {
    kind: Kind,
    src_line: u32,
    out_lines: u32 = 1,
    const Kind = enum { literal, interpolated, secret };
};

/// Attribute an interpolated file per source line: a line that resolved a
/// secret (or holds its placeholder) is `.secret`; one interpolation rewrote
/// is `.interpolated` at its source line, so commit can route an edit of it
/// to the fact or default that produced it, and one whose value filled
/// several output lines is a single `multi_line` segment, which routes no
/// edit; the rest keep the file's `nonSecretOrigin` at their source line.
fn recordInterpolated(
    arena: std.mem.Allocator,
    prov: ?*std.ArrayList(Segment),
    bytes: []const u8,
    file: ManagedFile,
    merged: bool,
    lines_out: []const OutLine,
    base_removed: []const u32,
) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (!routesByLine(file, merged)) {
        var secret_lines: std.ArrayList(bool) = .empty;
        var any_secret = false;
        for (lines_out) |ol| {
            any_secret = any_secret or ol.kind == .secret;
            try secret_lines.appendNTimes(arena, ol.kind == .secret, ol.out_lines);
        }
        return if (any_secret)
            recordPerLineSecret(arena, prov, bytes, file, merged, secret_lines.items, base_removed)
        else
            recordWhole(arena, prov, bytes, file, merged, base_removed);
    }
    var out_line: u32 = 0;
    for (lines_out) |ol| {
        if (out_line >= n) break;
        const len = @min(ol.out_lines, n - out_line);
        switch (ol.kind) {
            .secret => try prov_mod.map.append(arena, p, out_line, len, .secret),
            .interpolated => try prov_mod.map.append(arena, p, out_line, len, .{ .interpolated = .{
                .origin_line = source.head.sourceLine(base_removed, ol.src_line + 1),
                .multi_line = len > 1,
            } }),
            .literal => try appendEach(arena, p, out_line, len, nonSecretOrigin(file, merged, base_removed, ol.src_line)),
        }
        out_line += len;
    }
    if (out_line < n) try appendEach(arena, p, out_line, n - out_line, nonSecretOrigin(file, merged, base_removed, out_line));
}

fn appendEach(arena: std.mem.Allocator, p: *std.ArrayList(Segment), start: u32, len: u32, origin: prov_mod.map.Origin) !void {
    var i: u32 = 0;
    while (i < len) : (i += 1) try prov_mod.map.append(arena, p, start + i, 1, origin);
}

/// Returns the absolute paths of all layers that match `bindings`, sorted
/// least-specific first so a left-fold deep-merge applies them in
/// increasing precedence. The base file (if any) is always first.
fn collectMatchingLayers(
    arena: std.mem.Allocator,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
) ![]const []const u8 {
    var layers: std.ArrayList(LayerRef) = .empty;
    errdefer layers.deinit(arena);

    if (file.has_base) {
        try layers.append(arena, .{ .path = file.source_base_abs, .tuple = .{ .pairs = &.{} } });
    }
    for (file.overlays) |o| {
        const t = match_mod.effectiveOverlayTuple(o, bindings);
        if (!match_mod.matches(t, bindings)) continue;
        try layers.append(arena, .{ .path = o.path, .tuple = t });
    }

    std.mem.sort(LayerRef, layers.items, {}, LayerRef.lessSpecificFirst);

    var paths = try arena.alloc([]const u8, layers.items.len);
    for (layers.items, 0..) |layer, i| paths[i] = layer.path;
    return paths;
}

/// Public wrapper over `collectMatchingLayers`: the absolute paths of every
/// layer that matches `bindings`, least-specific-first (base, if any, first).
/// `mox commit` re-reads exactly this set to recompute per-key layer ownership
/// at commit time.
pub fn matchingLayerPaths(
    arena: std.mem.Allocator,
    file: ManagedFile,
    bindings: *const dsl.resolver.Resolver,
) ![]const []const u8 {
    return collectMatchingLayers(arena, file, bindings);
}

const LayerRef = struct {
    path: []const u8,
    tuple: source.tree.AxisTuple,

    // Total order: less specific first (so more-specific overlays override at
    // conflicting keys), then canonical tuple order so equal-specificity layers
    // fold in a filesystem-independent order -- a deterministic composition.
    fn lessSpecificFirst(_: void, a: LayerRef, b: LayerRef) bool {
        if (a.tuple.pairs.len != b.tuple.pairs.len) return a.tuple.pairs.len < b.tuple.pairs.len;
        if (a.tuple.canonicalLess(b.tuple)) return true;
        if (b.tuple.canonicalLess(a.tuple)) return false;
        // Equal-specificity, equal-canonical layers: tiebreak on the unique
        // path so the fold order is total and machine-independent.
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// A layer of a TOML, YAML or INI merge with each capture expanded, every
/// value written for its context: the merge reads the values, and the
/// emitter writes each in a style that holds it.
const Layer = struct {
    text: []const u8,
    display: []const u8,
    /// The layer's own line of each line of `text`, 1-based; empty when they
    /// are the same.
    lines: []const u32 = &.{},
    /// The head pass's removed lines, for the base layer.
    removed: []const u32 = &.{},
    secret: bool = false,
};

fn readLayer(arena: std.mem.Allocator, io: Io, file: ManagedFile, path: []const u8, machine_state_opt: ?*const machine.state.MachineState, secrets: ?catB.SecretCtx, diag: ?*interp.Diag) !Layer {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    return expandLayer(arena, io, file, path, content, &.{}, machine_state_opt, secrets, diag);
}

fn expandLayer(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    path: []const u8,
    text: []const u8,
    removed: []const u32,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    diag: ?*interp.Diag,
) !Layer {
    const display = layerDisplay(arena, file, path);
    if (machine_state_opt == null) return .{ .text = text, .display = display, .removed = removed };
    const ctx: interp.Ctx = .{
        .io = io,
        .machine = machine_state_opt,
        .repo_dir = file.repo_dir,
        .private_dir = file.private_dir,
        .secrets = if (secrets) |sc| .{ .env = sc.env, .cache = sc.cache } else null,
        .diag = diag,
    };
    var out: std.ArrayList(u8) = .empty;
    var enc = context.Encoder.init(context.kindFor(file.format, path, text), &out, secrets == null);
    var ectx = ctx;
    ectx.encoder = &enc;
    var lines: std.ArrayList(u32) = .empty;
    var secret = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (it.next()) |line| {
        n += 1;
        if (n > 1) try out.append(arena, '\n');
        const exp = try interp.expandTracked(arena, line, null, ectx);
        secret = secret or exp.secret;
        try lines.appendNTimes(arena, n, std.mem.count(u8, exp.bytes, "\n") + 1);
        try out.appendSlice(arena, exp.bytes);
    }
    const source_lines = try sourceLinesFor(arena, lines.items, removed);
    try interp.finishEncoderAt(arena, &enc, out.items, display, source_lines, diag);
    return .{ .text = out.items, .display = display, .lines = lines.items, .removed = removed, .secret = secret };
}

/// Each expanded line's line in the source file, through the head pass's
/// removed lines.
fn sourceLinesFor(arena: std.mem.Allocator, lines: []const u32, removed: []const u32) ![]const u32 {
    const out = try arena.alloc(u32, lines.len);
    for (lines, out) |l, *o| o.* = source.head.sourceLine(removed, l);
    return out;
}

/// A merge layer that would not parse: reported like a layer check, with
/// its location; in fixed text when a secret resolved into it.
fn layerFailed(arena: std.mem.Allocator, err: anyerror, format: source.format.Format, layer: Layer, diag: ?*interp.Diag) anyerror {
    if (err == error.OutOfMemory) return err;
    try validate.checkExpandedLayer(arena, format, layer.text, layer.display, layer.lines, layer.removed, layer.secret, diag);
    return err;
}

/// Record a merged output's provenance. A merge rewrites every line, so one
/// that resolved a secret is `.secret` whole.
fn mergedOutput(arena: std.mem.Allocator, file: ManagedFile, bytes: []const u8, secret: bool, prov: ?*std.ArrayList(Segment)) !?[]u8 {
    if (secret) {
        const all = try arena.alloc(bool, prov_mod.map.lineCount(bytes));
        @memset(all, true);
        try recordPerLineSecret(arena, prov, bytes, file, true, all, &.{});
    } else {
        try recordWhole(arena, prov, bytes, file, true, &.{});
    }
    return @constCast(bytes);
}

/// The home-relative key of the target `file` composes.
pub fn targetKey(file: ManagedFile) []const u8 {
    const p = file.source_base_path;
    return if (std.mem.startsWith(u8, p, "src/")) p["src/".len..] else p;
}

fn parseJsonFile(arena: std.mem.Allocator, io: Io, path: []const u8, dialect: json.Dialect) !json.Value {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    return json.parse(arena, try json_interp.escapeCaptureQuotes(arena, content), .{ .dialect = dialect });
}

test "lessSpecificFirst is a total order: equal tuples tiebreak on path" {
    // Two layers with the same axis tuple (e.g. `os=darwin.toml` and
    // `os=darwin.yaml`) must fold in a deterministic, path-ordered sequence
    // regardless of the order they were enumerated from the filesystem.
    const t = source.tree.AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    var forward = [_]LayerRef{
        .{ .path = "/x.d/os=darwin.toml", .tuple = t },
        .{ .path = "/x.d/os=darwin.yaml", .tuple = t },
    };
    var reverse = [_]LayerRef{
        .{ .path = "/x.d/os=darwin.yaml", .tuple = t },
        .{ .path = "/x.d/os=darwin.toml", .tuple = t },
    };
    std.mem.sort(LayerRef, &forward, {}, LayerRef.lessSpecificFirst);
    std.mem.sort(LayerRef, &reverse, {}, LayerRef.lessSpecificFirst);
    try std.testing.expectEqualStrings("/x.d/os=darwin.toml", forward[0].path);
    try std.testing.expectEqualStrings(forward[0].path, reverse[0].path);
    try std.testing.expectEqualStrings(forward[1].path, reverse[1].path);
}
