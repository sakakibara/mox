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
const ini_merge = @import("ini_merge.zig");
const interp = @import("interp.zig");
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
};

const max_layer_bytes: usize = 4 * 1024 * 1024;
const encode_buffer_initial: usize = 4096;

/// Compose a Category A managed file: TOML, JSON (JSONC input), and YAML
/// deep-merge; gitconfig and INI section-merge.
///
/// Cat A owns its own provenance. A single-layer file carrying `# mox:`
/// directives routes through Cat B, whose per-line segments (including
/// `.secret` for a resolved secret) flow straight into `prov`. Every other
/// route (structural merge, verbatim pass-through) is one whole-file segment,
/// `.secret` when interpolation resolved an inline `<secret:URI>` so its
/// cleartext is kept out of the applied-content cache and snapshots. `diag`, if
/// set, names the failing capture on a resolution error.
pub fn compose(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    if (formatOf(file.source_base_path)) |format| return switch (format) {
        .toml => composeToml(arena, io, file, bindings, machine_state_opt, secrets, prov, diag),
        .gitconfig => composeSectionMerge(arena, io, file, bindings, machine_state_opt, secrets, .gitconfig, prov, diag),
        .yaml => composeYaml(arena, io, file, bindings, machine_state_opt, secrets, prov, diag),
        .json => composeJson(arena, io, file, bindings, machine_state_opt, secrets, prov, diag),
        .ini => composeSectionMerge(arena, io, file, bindings, machine_state_opt, secrets, .generic, prov, diag),
    };
    // Cat A but unrecognized extension: shouldn't happen given the
    // detector's table, but fail loudly instead of silently.
    return error.NoBaseOrMatchingOverlay;
}

const Format = enum { toml, gitconfig, yaml, json, ini };

/// A base layer after the single leading-block pass: head directives parsed
/// once, consumed lines stripped, whole-file gate evaluated.
const Head = struct {
    /// Base text with every consumed head-directive line removed (ownership,
    /// check, and -- when it holds -- the whole-file gate line).
    text: []const u8,
    /// A leading whole-file gate evaluated false: the file is absent on this
    /// machine.
    absent: bool = false,
    /// A leading whole-file gate held: `text` is the gate's body and composes
    /// by the file's native category, never through Cat B.
    gate_on: bool = false,
};

/// Read the base layer and run the ONE leading-block pass: parse the head
/// once (ownership declarations, check argv, whole-file gate candidate),
/// strip the consumed lines, and evaluate the gate. An overlay seed
/// (`has_base == false`) is returned verbatim: a leading `mox:` line there
/// is inert content, and a gate belongs on a base file.
fn readBaseHead(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    path: []const u8,
    marker: []const u8,
    bindings: *const std.StringHashMap([]const u8),
) !Head {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    if (!file.has_base) return .{ .text = raw };
    const parsed = source.head.parse(arena, raw, marker) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // The walk has already refused a malformed head; keep the text
        // intact so the failure surfaces with a source location downstream.
        else => return .{ .text = raw },
    };
    const stripped = if (parsed.spans.len == 0) raw else try source.head.strip(arena, raw, marker);
    if (parsed.gate == null) return .{ .text = stripped };
    // The candidate is a whole-file existence gate only when the DSL agrees:
    // the file must parse, and the gate must run to EOF (a matching `end`
    // later makes it a region, composed through Cat B).
    const expr = wholeFileGateExpr(arena, stripped, marker) orelse return .{ .text = stripped };
    if (!dsl.axis.evaluate(expr, bindings)) return .{ .text = stripped, .absent = true };
    // The gate line is line 1 of the stripped text by construction; consume
    // exactly it.
    const nl = std.mem.indexOfScalar(u8, stripped, '\n');
    return .{ .text = if (nl) |n| stripped[n + 1 ..] else "", .gate_on = true };
}

fn formatOf(path: []const u8) ?Format {
    if (source.format.isGitConfigPath(path)) return .gitconfig;
    const Pair = struct { ext: []const u8, format: Format };
    const table = [_]Pair{
        .{ .ext = ".toml", .format = .toml },
        .{ .ext = ".yaml", .format = .yaml },
        .{ .ext = ".yml", .format = .yaml },
        .{ .ext = ".json", .format = .json },
        .{ .ext = ".ini", .format = .ini },
        .{ .ext = ".gitconfig", .format = .gitconfig },
    };
    var longest: ?Format = null;
    var longest_len: usize = 0;
    for (table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext) and entry.ext.len > longest_len) {
            longest = entry.format;
            longest_len = entry.ext.len;
        }
    }
    return longest;
}

fn composeToml(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    const layers = try collectMatchingLayers(arena, file, bindings);
    if (layers.len == 0) return null;

    const hd = try readBaseHead(arena, io, file, layers[0], "#", bindings);
    if (hd.absent) return null;

    // Single-layer base with `# mox:` content directives routes through Cat B for
    // include / from / when. A whole-file gate composes its body structurally.
    // The pass-through preserves comments, blank lines, and key ordering.
    if (layers.len == 1) {
        if (!hd.gate_on and containsMoxDirective(hd.text)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text);
        return interpolate(arena, io, file, false, hd.text, machine_state_opt, secrets, prov, diag);
    }

    // Multi-layer merge seeds from the head-processed base text, so no
    // consumed directive line reaches the parser.
    var merged: toml.Value = try toml.parse(arena, hd.text, .{});
    for (layers[1..]) |path| {
        const next = try parseFile(arena, io, path);
        merged = try toml_merge.mergeTables(arena, merged, next);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try toml.encode(&aw.writer, merged, .{});
    return interpolate(arena, io, file, true, aw.written(), machine_state_opt, secrets, prov, diag);
}

/// Compose a `.json` managed file. Mirrors `composeToml`: single layer
/// passes through verbatim (Cat B if it carries `// mox:` directives);
/// multiple layers deep-merge structurally. Input layers are parsed as
/// JSONC (comments and trailing commas accepted); merged output is
/// pretty-printed plain JSON, so comments survive only the single-layer
/// pass-through path.
fn composeJson(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    const layers = try collectMatchingLayers(arena, file, bindings);
    if (layers.len == 0) return null;

    const hd = try readBaseHead(arena, io, file, layers[0], "//", bindings);
    if (hd.absent) return null;

    if (layers.len == 1) {
        if (!hd.gate_on and containsMoxDirectiveJson(hd.text)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text);
        return interpolate(arena, io, file, false, hd.text, machine_state_opt, secrets, prov, diag);
    }

    // A blank seed (a directive-only base: nothing remains after the head
    // pass) is not a parseable JSON document; the overlays supply all
    // content, so the first one seeds the merge. TOML's empty-table parse
    // gives the same semantics for free.
    const blank = std.mem.trim(u8, hd.text, " \t\r\n").len == 0;
    var merged: json.Value = if (blank)
        try parseJsonFile(arena, io, layers[1])
    else
        try json.parse(arena, hd.text, .{ .dialect = .jsonc });
    for (layers[if (blank) 2 else 1..]) |path| {
        const next = try parseJsonFile(arena, io, path);
        merged = try json_merge.deepMerge(arena, merged, next);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, merged, .{ .indent = 2 });
    // Target files end with a newline, matching the toml composer's output.
    try aw.writer.writeByte('\n');
    return interpolate(arena, io, file, true, aw.written(), machine_state_opt, secrets, prov, diag);
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
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    const layers = try collectMatchingLayers(arena, file, bindings);
    if (layers.len == 0) return null;

    const hd = try readBaseHead(arena, io, file, layers[0], "#", bindings);
    if (hd.absent) return null;

    if (layers.len == 1) {
        if (!hd.gate_on and containsMoxDirective(hd.text)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text);
        return interpolate(arena, io, file, false, hd.text, machine_state_opt, secrets, prov, diag);
    }

    // Same blank-seed rule as JSON: a directive-only base leaves no
    // parseable document, so the first overlay seeds the merge.
    const blank = std.mem.trim(u8, hd.text, " \t\r\n").len == 0;
    var merged: yaml.Value = if (blank)
        try parseYamlFile(arena, io, layers[1])
    else
        try yaml.parse(arena, hd.text, .{});
    for (layers[if (blank) 2 else 1..]) |path| {
        const next = try parseYamlFile(arena, io, path);
        merged = try yaml_merge.deepMerge(arena, merged, next);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    // yaml.emit already terminates the document with a trailing newline,
    // matching the toml/json composers' single-newline output convention.
    try yaml.emit(&aw.writer, merged, .{});
    return interpolate(arena, io, file, true, aw.written(), machine_state_opt, secrets, prov, diag);
}

/// Compose a gitconfig or INI managed file via raw-line section-merge.
/// Mirrors `composeToml`: a single layer passes through verbatim (or
/// routes to Cat B when it carries `# mox:` directives); multiple layers
/// fold through `ini_merge.merge` in increasing specificity.
fn composeSectionMerge(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    dialect: ini_merge.Dialect,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    const layers = try collectMatchingLayers(arena, file, bindings);
    if (layers.len == 0) return null;

    const hd = try readBaseHead(arena, io, file, layers[0], "#", bindings);
    if (hd.absent) return null;

    if (layers.len == 1) {
        if (!hd.gate_on and containsMoxDirective(hd.text)) return try catB.composeTrackedContent(arena, io, file, bindings, machine_state_opt, secrets, prov, diag, hd.text);
        return interpolate(arena, io, file, false, hd.text, machine_state_opt, secrets, prov, diag);
    }

    // Raw-line merge preserves comments, so the head-processed seed matters
    // here (the parse-then-emit formats would drop directive comments anyway).
    var merged: []u8 = @constCast(hd.text);
    for (layers[1..]) |path| {
        const overlay = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
        merged = try ini_merge.merge(arena, merged, overlay, dialect);
    }
    return interpolate(arena, io, file, true, merged, machine_state_opt, secrets, prov, diag);
}

/// Heuristic: does `content` contain a `# mox: ...` line? Cheap substring
/// check is fine — gitconfig comment marker is always `#`, and any false
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

/// Run the `<machine.X>` / `<data.X>` / `<secret:URI>` interpolation pass over a
/// Cat A composed output and record the file's whole-file provenance segment.
/// No machine state means no interp: the bytes pass through unchanged, still
/// attributed a whole-file segment. A resolved inline secret makes the segment
/// `.secret` so its cleartext stays out of the applied-content cache and
/// snapshots.
fn interpolate(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    merged: bool,
    bytes: []const u8,
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    if (machine_state_opt == null) {
        try recordWhole(arena, prov, bytes, file, merged);
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
    var secret_seen = false;
    var line_secret: std.ArrayList(bool) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const exp = try interp.expandTracked(arena, line, null, ctx);
        if (exp.secret) secret_seen = true;
        // A capture is always within a line, so exp.bytes has no newline: one
        // output line per input line, aligned 1:1 with this flag.
        try line_secret.append(arena, exp.secret);
        try out.appendSlice(arena, exp.bytes);
    }
    const result = try out.toOwnedSlice(arena);
    if (secret_seen) {
        try recordPerLineSecret(arena, prov, result, file, merged, line_secret.items);
    } else {
        try recordWhole(arena, prov, result, file, merged);
    }
    return result;
}

/// The non-secret origin a structural Cat A route attributes its output to:
/// `.base` when the output is the base passed through verbatim, `.overlay` when
/// layers actually merged (line-level attribution is out of scope for a
/// structural fold, so commit routes such a file by key path instead).
/// `merged` is whether more than one layer folded, not whether the file
/// DECLARES overlays: an overlay that does not match this machine contributes
/// nothing, and a file left composing verbatim from its base still routes by
/// line.
fn nonSecretOrigin(file: ManagedFile, merged: bool) prov_mod.map.Origin {
    return if (file.has_base and !merged)
        .{ .base = .{ .line = 1 } }
    else
        .{ .overlay = .{ .path = if (file.source_base_abs.len > 0) file.source_base_abs else file.source_base_path } };
}

/// Attribute the whole of `bytes` to a single `nonSecretOrigin` segment for a
/// structural Cat A route (merge or verbatim pass-through) that resolved no
/// inline secret. An interpolated file that did carries a secret goes through
/// `recordPerLineSecret` instead, so only its secret lines are `.secret`.
fn recordWhole(
    arena: std.mem.Allocator,
    prov: ?*std.ArrayList(Segment),
    bytes: []const u8,
    file: ManagedFile,
    merged: bool,
) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    try p.append(arena, .{ .out_start = 0, .out_len = n, .origin = nonSecretOrigin(file, merged) });
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
) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    const normal = nonSecretOrigin(file, merged);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const is_secret = i < line_secret.len and line_secret[i];
        try prov_mod.map.append(arena, p, i, 1, if (is_secret) .secret else normal);
    }
}

/// Returns the absolute paths of all layers that match `bindings`, sorted
/// least-specific first so a left-fold deep-merge applies them in
/// increasing precedence. The base file (if any) is always first.
fn collectMatchingLayers(
    arena: std.mem.Allocator,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
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
    bindings: *const std.StringHashMap([]const u8),
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

fn parseFile(arena: std.mem.Allocator, io: Io, path: []const u8) !toml.Value {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    return toml.parse(arena, content, .{});
}

fn parseJsonFile(arena: std.mem.Allocator, io: Io, path: []const u8) !json.Value {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    return json.parse(arena, content, .{ .dialect = .jsonc });
}

fn parseYamlFile(arena: std.mem.Allocator, io: Io, path: []const u8) !yaml.Value {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_layer_bytes));
    return yaml.parse(arena, content, .{});
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
