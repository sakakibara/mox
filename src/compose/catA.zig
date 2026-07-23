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
const category = @import("category.zig");
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

fn formatOf(path: []const u8) ?Format {
    if (category.isGitConfigPath(path)) return .gitconfig;
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

    const base = try Io.Dir.cwd().readFileAlloc(io, layers[0], arena, .limited(max_layer_bytes));
    // A whole-file existence gate belongs on a base file; when there is no base,
    // `layers[0]` is an overlay and its leading `# mox:` line is inert content.
    const gated: ?[]const u8 = if (file.has_base) switch (try wholeFileGate(arena, base, "#", bindings)) {
        .off => return null,
        .on => |body| body,
        .none => null,
    } else null;

    // Single-layer base with `# mox:` content directives routes through Cat B for
    // include / from / when. A whole-file gate composes its body structurally.
    // The pass-through preserves comments, blank lines, and key ordering.
    if (layers.len == 1) {
        if (gated) |body| return interpolate(arena, io, file, false, body, machine_state_opt, secrets, prov, diag);
        if (containsMoxDirective(base)) return try catB.composeTracked(arena, io, file, bindings, machine_state_opt, secrets, prov, diag);
        return interpolate(arena, io, file, false, base, machine_state_opt, secrets, prov, diag);
    }

    // Multi-layer merge: the gate (if any) is already evaluated for the skip;
    // parse-then-emit drops its comment line, so the merge needs no strip.
    var merged: toml.Value = try parseFile(arena, io, layers[0]);
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

    const base = try Io.Dir.cwd().readFileAlloc(io, layers[0], arena, .limited(max_layer_bytes));
    const gated: ?[]const u8 = if (file.has_base) switch (try wholeFileGate(arena, base, "//", bindings)) {
        .off => return null,
        .on => |body| body,
        .none => null,
    } else null;

    if (layers.len == 1) {
        if (gated) |body| return interpolate(arena, io, file, false, body, machine_state_opt, secrets, prov, diag);
        if (containsMoxDirectiveJson(base)) return try catB.composeTracked(arena, io, file, bindings, machine_state_opt, secrets, prov, diag);
        return interpolate(arena, io, file, false, base, machine_state_opt, secrets, prov, diag);
    }

    var merged: json.Value = try parseJsonFile(arena, io, layers[0]);
    for (layers[1..]) |path| {
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

    const base = try Io.Dir.cwd().readFileAlloc(io, layers[0], arena, .limited(max_layer_bytes));
    const gated: ?[]const u8 = if (file.has_base) switch (try wholeFileGate(arena, base, "#", bindings)) {
        .off => return null,
        .on => |body| body,
        .none => null,
    } else null;

    if (layers.len == 1) {
        if (gated) |body| return interpolate(arena, io, file, false, body, machine_state_opt, secrets, prov, diag);
        if (containsMoxDirective(base)) return try catB.composeTracked(arena, io, file, bindings, machine_state_opt, secrets, prov, diag);
        return interpolate(arena, io, file, false, base, machine_state_opt, secrets, prov, diag);
    }

    var merged: yaml.Value = try parseYamlFile(arena, io, layers[0]);
    for (layers[1..]) |path| {
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

    const base = try Io.Dir.cwd().readFileAlloc(io, layers[0], arena, .limited(max_layer_bytes));
    const gated: ?[]const u8 = if (file.has_base) switch (try wholeFileGate(arena, base, "#", bindings)) {
        .off => return null,
        .on => |body| body,
        .none => null,
    } else null;

    if (layers.len == 1) {
        if (gated) |body| return interpolate(arena, io, file, false, body, machine_state_opt, secrets, prov, diag);
        if (containsMoxDirective(base)) return try catB.composeTracked(arena, io, file, bindings, machine_state_opt, secrets, prov, diag);
        return interpolate(arena, io, file, false, base, machine_state_opt, secrets, prov, diag);
    }

    // Raw-line merge preserves comments, so a held gate must be stripped from
    // the seed (unlike the parse-then-emit formats, which drop it).
    var merged: []u8 = @constCast(gated orelse base);
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

const Gate = union(enum) {
    /// No leading whole-file gate; the caller decides (content directives -> Cat
    /// B, plain content -> structural).
    none,
    /// A whole-file gate that fails: the file is absent.
    off,
    /// A whole-file gate that holds: compose this body (the gate line removed)
    /// by the file's native category, not Cat B.
    on: []const u8,
};

/// A leading `<marker> mox: when <expr>` with no matching `end` (gating to EOF)
/// conditions a structured file's existence without turning it into Cat B text.
fn wholeFileGate(arena: std.mem.Allocator, content: []const u8, marker: []const u8, bindings: *const std.StringHashMap([]const u8)) !Gate {
    const parsed = dsl.driver.parseFile(arena, content, marker, null) catch return .none;
    if (parsed.directives.len == 0) return .none;
    const first = parsed.directives[0];
    if (first.kind != .when_gate or first.start_line > 1 or !first.kind.when_gate.to_eof) return .none;
    const gate = first.kind.when_gate.when orelse return .none;
    if (!dsl.axis.evaluate(gate, bindings)) return .off;
    const nl = std.mem.indexOfScalar(u8, content, '\n') orelse return .{ .on = "" };
    return .{ .on = content[nl + 1 ..] };
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
