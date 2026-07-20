const std = @import("std");
const data = @import("../data/root.zig");
const dsl = @import("../dsl/root.zig");
const machine = @import("../machine/root.zig");
const secret = @import("../secret/root.zig");
const Env = @import("env").Env;

const Io = std.Io;

pub const InterpError = error{
    UnknownField,
    NonScalarField,
    UnknownMachineField,
    MachineRefWithoutState,
    EntryRefWithoutRecord,
    UnresolvedFallbackChain,
    UnknownDataKey,
    NonScalarData,
    DataFileError,
    MalformedDataCapture,
    DataRefWithoutContext,
    SecretRefWithoutContext,
    OutOfMemory,
} || secret.uri.ParseError || secret.resolver.ResolveError;

pub const LintError = error{
    AdjacentCaptures,
    DuplicateCapture,
    EmptyCaptureName,
    EmptySecretUri,
    UnclosedCapture,
    MalformedDataCapture,
    OutOfMemory,
};

/// Secret-resolution inputs: the process environment (for `env:` URIs and
/// backend subprocesses) and the apply-wide lookup cache. Present only on
/// resolving paths (apply/commit); a null `secrets` makes `<secret:URI>` emit a
/// `<SECRET:uri>` placeholder instead of resolving.
pub const Secrets = struct {
    env: Env,
    cache: *secret.cache.Cache,
};

/// A loop variable binding in the interpolation scope. A record loop
/// (`for id in "data/ids.toml"`) binds a table row; an array-element loop
/// (`for url in id.match_urls`) binds a scalar string. Defined in
/// `dsl.row_expr` so `where`/`when` row predicates share the same scope shape.
pub const Binding = dsl.row_expr.Binding;

/// One frame of the scope stack. `name` is the loop variable. The stack is
/// ordered innermost-first, so the first frame whose name matches a capture's
/// head resolves it (inner loops shadow outer ones).
pub const Frame = dsl.row_expr.Frame;

/// Per-file compose signal sink. Records the failing capture's text (so a CLI
/// can name WHICH capture failed after `compose failed: <errorName>`; the fixed
/// buffer keeps it owned independently of the compose arena, and a secret
/// failure records the URI only, never a resolved value), and whether the file
/// resolved a secret from a dedicated secret manager (`op://`/`pass://`) -- the
/// signal apply uses to auto-restrict such a live file to 0600.
pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    /// True once an `op://` or `pass://` secret resolved into this file. Only
    /// these dedicated-manager schemes are treated as unambiguously sensitive;
    /// `env:`/`file://`/`cmd:` are general-purpose and left to an explicit mode.
    manager_secret: bool = false,

    pub fn set(self: *Diag, text: []const u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    pub fn capture(self: *const Diag) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

/// Whether a resolved secret URI came from a dedicated secret manager, so its
/// output file warrants auto-0600. `env:`/`file://`/`cmd:` are ambiguous
/// (often non-secret, e.g. a `cmd:` computing a theme name) and excluded.
pub fn isManagerSecretUri(uri: []const u8) bool {
    return std.mem.startsWith(u8, uri, "op://") or std.mem.startsWith(u8, uri, "pass://");
}

/// Context threaded through capture expansion. Bundles the machine facts and
/// the roots needed to resolve `<data.FILE.KEY>` captures (the private layer
/// shadows the repo, matching `mox data get`), plus the optional secret
/// resolver for `<secret:URI>` captures and an optional diagnostic sink that
/// records which capture failed when a resolution error fires.
pub const Ctx = struct {
    io: ?Io = null,
    machine: ?*const machine.state.MachineState = null,
    repo_dir: []const u8 = "",
    private_dir: []const u8 = "",
    secrets: ?Secrets = null,
    diag: ?*Diag = null,
    /// Loop-variable bindings, innermost first. Empty outside any loop.
    scope: []const Frame = &.{},
};

const ScopeResult = union(enum) {
    /// The capture resolved to these bytes.
    value: []const u8,
    /// The head named a scope frame, but the reference is unfulfilled (a field
    /// absent from the record, a field on a scalar, or a bare record ref). A
    /// `| default` may rescue it; otherwise it is an UnknownField.
    missing,
    /// The head is not a scope variable: fall through to other namespaces.
    miss,
};

/// Resolve `name` or `name.field` against the scope stack (innermost first).
fn resolveScope(arena: std.mem.Allocator, scope: []const Frame, inner: []const u8) InterpError!ScopeResult {
    if (scope.len == 0) return .miss;
    const dot = std.mem.indexOfScalar(u8, inner, '.');
    const head = if (dot) |d| inner[0..d] else inner;
    for (scope) |frame| {
        if (!std.mem.eql(u8, frame.name, head)) continue;
        switch (frame.value) {
            .scalar => |s| {
                if (dot != null) return .missing; // a scalar has no fields
                return .{ .value = s };
            },
            .record => |r| {
                const d = dot orelse return .missing; // a bare record ref is not a value
                if (r.get(inner[d + 1 ..])) |v| return .{ .value = try v.format(arena) };
                return .missing;
            },
        }
    }
    return .miss;
}

/// Scope resolution for a fallback-chain member: null when the head is not a
/// scope variable (try other namespaces), else the resolved bytes ("" when the
/// frame matched but the field is absent, so the chain falls through).
fn scopeChainMember(arena: std.mem.Allocator, scope: []const Frame, member: []const u8) InterpError!?[]const u8 {
    return switch (try resolveScope(arena, scope, member)) {
        .value => |v| v,
        .missing => "",
        .miss => null,
    };
}

/// Record the failing capture into the context's diagnostic sink, when set.
fn noteDiag(ctx: Ctx, text: []const u8) void {
    if (ctx.diag) |d| d.set(text);
}

/// Index of the `>` that closes the capture opened at `open` (a `<`), null when
/// unclosed. A `| default "..."` value may itself contain `>`, so when that
/// marker is present the close is taken to be the `>` immediately after the
/// default's closing quote (`">`) rather than the first `>` seen.
fn captureCloseIndex(template: []const u8, open: usize) ?usize {
    // A `<secret:URI>` capture runs the URI verbatim to the first UNESCAPED `>`:
    // `"` and a literal ` | default "` inside a cmd: URI are payload, not
    // capture syntax, and a `\>` is a literal `>` in the payload (see
    // secretCloseIndex).
    if (std.mem.startsWith(u8, template[open + 1 ..], "secret:"))
        return secretCloseIndex(template, open + 1);
    const naive = std.mem.indexOfScalarPos(u8, template, open + 1, '>') orelse return null;
    const marker = " | default \"";
    // Search only within this capture (up to the first `>`): a marker after it
    // belongs to a later capture. Bounding the scan keeps a template with many
    // captures from being O(n^2).
    const mpos = std.mem.indexOfPos(u8, template[0..naive], open + 1, marker) orelse return naive;
    const qstart = mpos + marker.len;
    var k = qstart;
    while (k + 1 < template.len) : (k += 1) {
        if (template[k] == '"' and template[k + 1] == '>') return k + 1;
    }
    // Malformed or unusual default (no `">`): fall back to the first `>`.
    return naive;
}

/// Index of the `>` closing a `<secret:URI>` capture, scanning from `start` =
/// the first URI byte. Inside the URI a backslash escapes the next byte, so a
/// `\>` is a literal `>` in the payload (letting a `cmd:` URI carry a shell
/// redirect such as `2>&1`) and does NOT close the capture, and `\\` is a
/// literal backslash; any other backslash stands for itself. Returns null when
/// no unescaped `>` is found.
fn secretCloseIndex(template: []const u8, start: usize) ?usize {
    var k = start;
    while (k < template.len) {
        const ch = template[k];
        if (ch == '\\' and k + 1 < template.len and
            (template[k + 1] == '>' or template[k + 1] == '\\'))
        {
            k += 2;
            continue;
        }
        if (ch == '>') return k;
        k += 1;
    }
    return null;
}

/// Decode a secret URI's escapes into the payload handed to the resolver:
/// `\>` -> `>`, `\\` -> `\`, every other byte (including a lone backslash)
/// verbatim. Returns `raw` unchanged when it carries no escapable backslash,
/// so the common URI allocates nothing.
fn unescapeSecretUri(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var needs = false;
    var j: usize = 0;
    while (j + 1 < raw.len) : (j += 1) {
        if (raw[j] == '\\' and (raw[j + 1] == '>' or raw[j + 1] == '\\')) {
            needs = true;
            break;
        }
    }
    if (!needs) return raw;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    var k: usize = 0;
    while (k < raw.len) {
        if (raw[k] == '\\' and k + 1 < raw.len and
            (raw[k + 1] == '>' or raw[k + 1] == '\\'))
        {
            try buf.append(arena, raw[k + 1]);
            k += 2;
            continue;
        }
        try buf.append(arena, raw[k]);
        k += 1;
    }
    return try buf.toOwnedSlice(arena);
}

/// Check a template for forbidden patterns. Returns nothing on success. The
/// duplicate-capture set is arena-owned, so it stays unbounded regardless of
/// how many distinct captures a template carries.
pub fn lint(arena: std.mem.Allocator, template: []const u8) LintError!void {
    var seen = std.StringHashMap(void).init(arena);
    var i: usize = 0;
    var prev_was_capture_end = false;
    while (i < template.len) {
        const c = template[i];
        if (c == '<') {
            if (prev_was_capture_end) return error.AdjacentCaptures;
            const close = captureCloseIndex(template, i) orelse return error.UnclosedCapture;
            const inner = template[i + 1 .. close];
            if (inner.len == 0) return error.EmptyCaptureName;
            try lintCapture(inner);
            if ((try seen.getOrPut(inner)).found_existing) return error.DuplicateCapture;
            i = close + 1;
            prev_was_capture_end = true;
            continue;
        }
        prev_was_capture_end = false;
        i += 1;
    }
}

/// Expand a template's `<...>` captures. Returns arena-owned bytes. The
/// template MUST have already been linted with `lint`.
///
/// Contract:
///   - record_opt non-null: `<entry.X>` and bare `<X>` resolve against it.
///     Unknown fields are an error (template-style behavior).
///   - record_opt null: `<entry.X>` is an error; bare `<X>` is left as-is
///     (literal pass-through). This is the "fragment" mode used after pacifier
///     strip, where most `<...>` are not captures (heredocs, shell redirs, etc.).
///   - `<machine.X>` / `<env.X>` resolve against `ctx.machine` when non-null;
///     an error otherwise.
///   - `<data.FILE.KEY>` / `<data.FILE.TABLE.KEY>` read a committed scalar from
///     `data/FILE.toml` (private layer shadows repo), using `ctx.io` +
///     `ctx.repo_dir` + `ctx.private_dir`. A missing file/key is an error
///     (rescuable by `| default`); a non-scalar value is fatal regardless.
///   - `<secret:URI>` resolves the URI (env/file/op/pass/cmd) through
///     `ctx.secrets` and splices the plaintext mid-line; with no `ctx.secrets`
///     it emits a `<SECRET:uri>` placeholder. A resolution failure is fatal.
pub fn expand(
    arena: std.mem.Allocator,
    template: []const u8,
    record_opt: ?*const std.StringHashMap(data.value.Value),
    ctx: Ctx,
) InterpError![]u8 {
    return (try expandTracked(arena, template, record_opt, ctx)).bytes;
}

/// Result of an expansion: the arena-owned bytes, plus whether a `<secret:URI>`
/// capture actually RESOLVED a secret into them (false when there was none, or
/// when a null `ctx.secrets` turned it into a placeholder). Callers that record
/// provenance use `secret` to mark the emitted span `.secret`, so its resolved
/// cleartext is kept out of the applied-content cache and snapshots.
pub const Expansion = struct { bytes: []u8, secret: bool };

/// `expand` with the secret-resolution signal. See `expand` for the capture
/// contract; the only addition is the returned `secret` flag.
pub fn expandTracked(
    arena: std.mem.Allocator,
    template: []const u8,
    record_opt: ?*const std.StringHashMap(data.value.Value),
    ctx: Ctx,
) InterpError!Expansion {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var secret_seen = false;

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '<') {
            const close = captureCloseIndex(template, i) orelse {
                try out.append(arena, c);
                i += 1;
                continue;
            };
            const inner_raw = template[i + 1 .. close];

            // `<secret:URI>`: resolve the URI through the shared resolver+cache
            // and splice the plaintext mid-line, or emit the `<SECRET:uri>`
            // placeholder with no secrets context. The URI is verbatim to `>`,
            // so it is never default- or chain-split.
            if (std.mem.startsWith(u8, inner_raw, "secret:")) {
                try appendSecret(arena, &out, ctx, inner_raw["secret:".len..], &secret_seen);
                i = close + 1;
                continue;
            }

            // Optional ` | default "..."` suffix. `<machine.x | default "y">`
            // returns "y" when the field is missing instead of erroring.
            const split = splitDefault(inner_raw);
            const inner = split.field;
            const default_opt = split.default;

            // Fallback chain: `<env.a | env.b | machine.c | default "">`.
            // First non-empty member wins; exhausting the chain without a
            // trailing default is a compose error (fail-fast, same policy
            // as a missing single interpolation). A chain containing a bare
            // name outside template mode is not a capture: pass through.
            if (std.mem.indexOf(u8, inner, " | ") != null) {
                switch (try resolveChain(arena, &out, inner, default_opt, record_opt, ctx)) {
                    .resolved => {
                        i = close + 1;
                        continue;
                    },
                    .not_a_capture => {
                        try out.appendSlice(arena, template[i .. close + 1]);
                        i = close + 1;
                        continue;
                    },
                }
            }

            // Loop variables (innermost first) resolve before the fixed
            // namespaces, so `<id.slug>` / `<url>` bind to the enclosing loops.
            // A head that names no frame falls through (machine/env/data are
            // never shadowed, since no loop is named for them).
            switch (try resolveScope(arena, ctx.scope, inner)) {
                .value => |v| {
                    try out.appendSlice(arena, v);
                    i = close + 1;
                    continue;
                },
                .missing => {
                    if (default_opt) |d| {
                        try out.appendSlice(arena, d);
                        i = close + 1;
                        continue;
                    }
                    noteDiag(ctx, inner);
                    return error.UnknownField;
                },
                .miss => {},
            }

            if (std.mem.startsWith(u8, inner, "machine.")) {
                const m = ctx.machine orelse return error.MachineRefWithoutState;
                const field = inner[8..];
                const formatted = formatMachineField(arena, m, field) catch |e| switch (e) {
                    error.UnknownMachineField => if (default_opt) |d| try arena.dupe(u8, d) else {
                        noteDiag(ctx, inner);
                        return e;
                    },
                    else => return e,
                };
                try out.appendSlice(arena, formatted);
                i = close + 1;
                continue;
            }

            if (std.mem.startsWith(u8, inner, "entry.")) {
                const r = record_opt orelse return error.EntryRefWithoutRecord;
                const field = inner[6..];
                if (r.get(field)) |v| {
                    const formatted = try v.format(arena);
                    try out.appendSlice(arena, formatted);
                } else if (default_opt) |d| {
                    try out.appendSlice(arena, d);
                } else {
                    return error.UnknownField;
                }
                i = close + 1;
                continue;
            }

            if (std.mem.startsWith(u8, inner, "data.")) {
                // `<data.FILE.KEY>` reads a committed shared scalar. Missing
                // file/key is rescued by a default; a non-scalar value never is.
                const spec = parseDataSpec(inner[5..]) orelse {
                    noteDiag(ctx, inner);
                    return error.MalformedDataCapture;
                };
                const looked = lookupData(arena, ctx, spec) catch |e| {
                    // A missing data context is rescuable by a default, exactly
                    // like a missing file/key; any other lookup error is fatal.
                    if (e == error.DataRefWithoutContext and default_opt != null) {
                        try out.appendSlice(arena, default_opt.?);
                        i = close + 1;
                        continue;
                    }
                    noteDiag(ctx, inner);
                    return e;
                };
                if (looked) |txt| {
                    try out.appendSlice(arena, txt);
                } else if (default_opt) |d| {
                    try out.appendSlice(arena, d);
                } else {
                    noteDiag(ctx, inner);
                    return error.UnknownDataKey;
                }
                i = close + 1;
                continue;
            }

            if (std.mem.startsWith(u8, inner, "env.")) {
                // `<env.NAME>` substitutes the captured value of an env var
                // (from `MachineState.env_values`). Empty string when the
                // name isn't in the watch list or isn't set, OR the default
                // when one is supplied via `| default "..."`.
                const m = ctx.machine orelse return error.MachineRefWithoutState;
                const name = inner[4..];
                var resolved: []const u8 = "";
                var found = false;
                for (m.env_values) |ev| {
                    if (std.mem.eql(u8, ev.name, name)) {
                        resolved = ev.value;
                        found = true;
                        break;
                    }
                }
                if (!found and default_opt != null) resolved = default_opt.?;
                try out.appendSlice(arena, resolved);
                i = close + 1;
                continue;
            }

            // Bare name: resolve against record if present (template mode),
            // else pass through literally (fragment mode).
            if (record_opt) |r| {
                if (r.get(inner)) |v| {
                    const formatted = try v.format(arena);
                    try out.appendSlice(arena, formatted);
                    i = close + 1;
                    continue;
                }
                return error.UnknownField;
            }
            try out.append(arena, c);
            i += 1;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }

    return .{ .bytes = try out.toOwnedSlice(arena), .secret = secret_seen };
}

/// Splice a `<secret:URI>` capture. With a secrets context, resolve through the
/// shared cache and mark `secret_seen`; without one, emit the read-path
/// `<SECRET:uri>` placeholder so no resolution happens off the apply path. A
/// resolution failure propagates a fatal error whose name identifies the
/// failure kind -- never the resolved value, which does not exist on failure.
fn appendSecret(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ctx: Ctx,
    uri_str: []const u8,
    secret_seen: *bool,
) InterpError!void {
    if (ctx.secrets) |sc| {
        const io = ctx.io orelse return error.SecretRefWithoutContext;
        const uri = try unescapeSecretUri(arena, uri_str);
        // A dedicated-manager secret marks the file for auto-0600. Set before
        // resolving: a resolution failure aborts the file's compose, so the
        // flag is only ever consumed by apply on a successful compose.
        if (isManagerSecretUri(uri)) {
            if (ctx.diag) |d| d.manager_secret = true;
        }
        const value = secret.resolver.resolveCached(arena, io, sc.env, sc.cache, uri) catch |e| {
            // Record the URI as written (escaped); a resolution failure has no
            // value to leak.
            noteDiag(ctx, uri_str);
            return e;
        };
        try out.appendSlice(arena, value);
        secret_seen.* = true;
    } else {
        // The placeholder echoes the URI as written, so a `\>` stays visible
        // rather than surfacing a bare `>` that would look like an early close.
        try out.appendSlice(arena, "<SECRET:");
        try out.appendSlice(arena, uri_str);
        try out.append(arena, '>');
    }
}

const ChainResult = enum { resolved, not_a_capture };

/// Resolve a multi-member fallback chain, appending the winning value to
/// `out`. Members resolve to empty (and fall through) when their field is
/// unknown or unset; `entry.` members still error without a record, since a
/// chain touching row data outside a loop is a template bug, not a fallback.
fn resolveChain(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    inner: []const u8,
    default_opt: ?[]const u8,
    record_opt: ?*const std.StringHashMap(data.value.Value),
    ctx: Ctx,
) InterpError!ChainResult {
    var chosen: ?[]const u8 = null;
    var members = std.mem.splitSequence(u8, inner, " | ");
    while (members.next()) |member_raw| {
        const member = std.mem.trim(u8, member_raw, " \t");
        var value: []const u8 = "";
        if (try scopeChainMember(arena, ctx.scope, member)) |v| {
            value = v;
        } else if (std.mem.startsWith(u8, member, "machine.")) {
            const m = ctx.machine orelse return error.MachineRefWithoutState;
            value = formatMachineField(arena, m, member[8..]) catch |e| switch (e) {
                error.UnknownMachineField => "",
                else => return e,
            };
        } else if (std.mem.startsWith(u8, member, "env.")) {
            const m = ctx.machine orelse return error.MachineRefWithoutState;
            for (m.env_values) |ev| {
                if (std.mem.eql(u8, ev.name, member[4..])) {
                    value = ev.value;
                    break;
                }
            }
        } else if (std.mem.startsWith(u8, member, "data.")) {
            // A `data.` chain member falls through on a missing file/key, but
            // a non-scalar value stays fatal even mid-chain.
            const spec = parseDataSpec(member[5..]) orelse {
                noteDiag(ctx, member);
                return error.MalformedDataCapture;
            };
            const looked = lookupData(arena, ctx, spec) catch |e| {
                // No data context: fall through like a missing key so the
                // chain's own default can rescue it; other errors stay fatal.
                if (e == error.DataRefWithoutContext) continue;
                noteDiag(ctx, member);
                return e;
            };
            if (looked) |txt| value = txt;
        } else if (std.mem.startsWith(u8, member, "entry.")) {
            const r = record_opt orelse return error.EntryRefWithoutRecord;
            if (r.get(member[6..])) |v| value = try v.format(arena);
        } else {
            const r = record_opt orelse return .not_a_capture;
            if (r.get(member)) |v| value = try v.format(arena) else return .not_a_capture;
        }
        if (chosen == null and value.len > 0) chosen = value;
    }
    const winner = chosen orelse default_opt orelse return error.UnresolvedFallbackChain;
    try out.appendSlice(arena, winner);
    return .resolved;
}

const DataSpec = struct { file: []const u8, table: ?[]const u8, key: []const u8 };

/// Resolve a `<data.FILE.KEY>` spec against the context. Returns the rendered
/// scalar bytes, null when the file/table/key is absent (so a `| default` can
/// rescue it), or a fatal error for a non-scalar value or a load failure.
fn lookupData(arena: std.mem.Allocator, ctx: Ctx, spec: DataSpec) InterpError!?[]const u8 {
    const io = ctx.io orelse return error.DataRefWithoutContext;
    if (ctx.repo_dir.len == 0) return error.DataRefWithoutContext;
    return data.source.lookupScalar(arena, io, ctx.repo_dir, ctx.private_dir, spec.file, spec.table, spec.key);
}

/// Parse the segments after `data.` into a spec, or null when the depth is
/// wrong (must be FILE.KEY or FILE.TABLE.KEY -- rejects `<data.x>` and anything
/// deeper) or a segment is malformed. FILE, TABLE, and KEY all match
/// `[a-z][a-z0-9_-]*` -- TOML bare keys admit `-`, and the leading-lowercase
/// shape keeps FILE from naming a path outside `data/`.
fn parseDataSpec(rest: []const u8) ?DataSpec {
    var it = std.mem.splitScalar(u8, rest, '.');
    const s0 = it.next() orelse return null;
    const s1 = it.next() orelse return null;
    const s2 = it.next();
    if (it.next() != null) return null;
    if (!validName(s0)) return null;
    if (s2) |k| {
        if (!validName(s1)) return null;
        if (!validName(k)) return null;
        return .{ .file = s0, .table = s1, .key = k };
    }
    if (!validName(s1)) return null;
    return .{ .file = s0, .table = null, .key = s1 };
}

fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Validate a capture body's `data.` members: each must be a well-formed
/// FILE.KEY / FILE.TABLE.KEY reference. Other namespaces are not checked here
/// (they resolve at expand time); this only exists to reject malformed data
/// captures like `<data.x>` up front.
fn lintCapture(inner: []const u8) LintError!void {
    if (std.mem.startsWith(u8, inner, "secret:")) {
        if (inner.len == "secret:".len) return error.EmptySecretUri;
        return;
    }
    const body = splitDefault(inner).field;
    // A capture that is only a default (`< | default "x">`) or is all whitespace
    // has no field to resolve: lint would pass it but expand would fail, so
    // reject it here to keep lint and expand in agreement.
    if (std.mem.trim(u8, body, " \t").len == 0) return error.EmptyCaptureName;
    var members = std.mem.splitSequence(u8, body, " | ");
    while (members.next()) |member_raw| {
        const member = std.mem.trim(u8, member_raw, " \t");
        if (std.mem.startsWith(u8, member, "data.")) {
            if (parseDataSpec(member[5..]) == null) return error.MalformedDataCapture;
        }
    }
}

/// Split a `<...>` capture body into (field, default). Recognizes the suffix
/// ` | default "..."` and strips it from the field reference.
fn splitDefault(inner: []const u8) struct { field: []const u8, default: ?[]const u8 } {
    const marker = " | default \"";
    const idx = std.mem.indexOf(u8, inner, marker) orelse return .{ .field = inner, .default = null };
    const after = inner[idx + marker.len ..];
    const close = std.mem.lastIndexOfScalar(u8, after, '"') orelse return .{ .field = inner, .default = null };
    const field = std.mem.trimEnd(u8, inner[0..idx], " \t");
    return .{ .field = field, .default = after[0..close] };
}

fn formatMachineField(
    arena: std.mem.Allocator,
    m: *const machine.state.MachineState,
    field: []const u8,
) InterpError![]const u8 {
    if (std.mem.eql(u8, field, "os")) return arena.dupe(u8, m.os);
    if (std.mem.eql(u8, field, "arch")) return arena.dupe(u8, m.arch);
    if (std.mem.eql(u8, field, "hostname")) return arena.dupe(u8, m.hostname);
    if (std.mem.eql(u8, field, "username")) return arena.dupe(u8, m.username);
    if (std.mem.eql(u8, field, "home")) return arena.dupe(u8, m.home);
    if (std.mem.eql(u8, field, "brew_prefix")) return arena.dupe(u8, m.brew_prefix);
    if (std.mem.eql(u8, field, "cargo_home")) return arena.dupe(u8, m.cargo_home);
    if (std.mem.eql(u8, field, "gopath")) return arena.dupe(u8, m.gopath);
    if (std.mem.eql(u8, field, "pnpm_home")) return arena.dupe(u8, m.pnpm_home);
    if (std.mem.eql(u8, field, "xdg_config_home")) return arena.dupe(u8, m.xdg_config_home);
    if (std.mem.eql(u8, field, "xdg_cache_home")) return arena.dupe(u8, m.xdg_cache_home);
    if (std.mem.eql(u8, field, "xdg_data_home")) return arena.dupe(u8, m.xdg_data_home);
    if (std.mem.eql(u8, field, "xdg_state_home")) return arena.dupe(u8, m.xdg_state_home);
    // `tool_path.<name>` substitutes the first-hit absolute path of a
    // tool found on PATH (chezmoi's `lookPath`). Empty string when not found.
    if (std.mem.startsWith(u8, field, "tool_path.")) {
        const tool_name = field[10..];
        for (m.tool_paths) |tp| {
            if (std.mem.eql(u8, tp.name, tool_name)) return arena.dupe(u8, tp.path);
        }
        return arena.dupe(u8, "");
    }
    for (m.custom_facts) |f| {
        if (std.mem.eql(u8, field, f.name)) return arena.dupe(u8, f.value);
    }
    return error.UnknownMachineField;
}

test "splitDefault: no default" {
    const r = splitDefault("machine.email");
    try std.testing.expectEqualStrings("machine.email", r.field);
    try std.testing.expect(r.default == null);
}

test "splitDefault: with default" {
    const r = splitDefault("machine.email | default \"x@y.com\"");
    try std.testing.expectEqualStrings("machine.email", r.field);
    try std.testing.expectEqualStrings("x@y.com", r.default.?);
}

test "splitDefault: empty default value is fine" {
    const r = splitDefault("env.HTTP_PROXY | default \"\"");
    try std.testing.expectEqualStrings("env.HTTP_PROXY", r.field);
    try std.testing.expectEqualStrings("", r.default.?);
}

/// Lint against a throwaway arena, so a test needs only the template string.
fn lintT(template: []const u8) LintError!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return lint(arena.allocator(), template);
}

test "lint: clean template" {
    try lintT("abbr <entry.key>=\"<entry.expansion>\"");
}

test "lint: a duplicate past 64 distinct captures is still flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    while (n < 70) : (n += 1) {
        const cap = try std.fmt.allocPrint(a, "<entry.f{d}> ", .{n});
        try buf.appendSlice(a, cap);
    }
    // Re-use the first capture: a duplicate well beyond the old 64-slot window.
    try buf.appendSlice(a, "<entry.f0>");
    try std.testing.expectError(error.DuplicateCapture, lint(a, buf.items));
}

test "lint: adjacent captures rejected" {
    try std.testing.expectError(error.AdjacentCaptures, lintT("<a><b>"));
}

test "lint: duplicate name rejected" {
    try std.testing.expectError(error.DuplicateCapture, lintT("<entry.k> and <entry.k>"));
}

test "lint: unclosed capture rejected" {
    try std.testing.expectError(error.UnclosedCapture, lintT("<entry.unclosed"));
}

test "lint: empty capture name rejected" {
    try std.testing.expectError(error.EmptyCaptureName, lintT("<>"));
}

test "lint: too-few-segment data capture rejected" {
    try std.testing.expectError(error.MalformedDataCapture, lintT("<data.x>"));
}

test "lint: too-deep data capture rejected" {
    try std.testing.expectError(error.MalformedDataCapture, lintT("<data.a.b.c.d>"));
}

test "lint: well-formed data captures accepted" {
    try lintT("key = <data.signing.personal_key>");
    try lintT("key = <data.signing.keys.personal>");
    try lintT("<env.X | data.signing.personal_key | default \"\">");
}

test "parseDataSpec: depths and shapes" {
    const two = parseDataSpec("signing.personal_key").?;
    try std.testing.expectEqualStrings("signing", two.file);
    try std.testing.expect(two.table == null);
    try std.testing.expectEqualStrings("personal_key", two.key);

    const three = parseDataSpec("signing.keys.personal").?;
    try std.testing.expectEqualStrings("signing", three.file);
    try std.testing.expectEqualStrings("keys", three.table.?);
    try std.testing.expectEqualStrings("personal", three.key);

    try std.testing.expect(parseDataSpec("x") == null); // too few
    try std.testing.expect(parseDataSpec("a.b.c.d") == null); // too deep
    try std.testing.expect(parseDataSpec("a/b.key") == null); // path in FILE
    try std.testing.expect(parseDataSpec("a.") == null); // empty key
    try std.testing.expect(parseDataSpec("A.b") == null); // uppercase FILE
}

test "parseDataSpec: hyphenated TABLE and KEY are accepted (TOML bare keys allow '-')" {
    const two = parseDataSpec("my-file.signing-key").?;
    try std.testing.expectEqualStrings("my-file", two.file);
    try std.testing.expect(two.table == null);
    try std.testing.expectEqualStrings("signing-key", two.key);

    const three = parseDataSpec("host.ssh-keys.personal-1").?;
    try std.testing.expectEqualStrings("host", three.file);
    try std.testing.expectEqualStrings("ssh-keys", three.table.?);
    try std.testing.expectEqualStrings("personal-1", three.key);

    try std.testing.expect(parseDataSpec("-lead.k") == null); // dash cannot lead
}

test "expand: simple substitution" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    var record = std.StringHashMap(data.value.Value).init(fba.allocator());
    try record.put("key", .{ .string = "ll" });
    const out = try expand(fba.allocator(), "abbr <entry.key>", &record, .{});
    try std.testing.expectEqualStrings("abbr ll", out);
}

test "expand: int and bool" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    var record = std.StringHashMap(data.value.Value).init(fba.allocator());
    try record.put("p", .{ .int = 42 });
    try record.put("e", .{ .bool = true });
    const out = try expand(fba.allocator(), "p=<entry.p> e=<entry.e>", &record, .{});
    try std.testing.expectEqualStrings("p=42 e=true", out);
}

test "expand: missing field errors" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    var record = std.StringHashMap(data.value.Value).init(fba.allocator());
    const result = expand(fba.allocator(), "<entry.missing>", &record, .{});
    try std.testing.expectError(error.UnknownField, result);
}

test "expand: a data capture's default rescues a missing data context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No ctx.io / repo_dir means the data layer is unreachable, but the
    // default rescues it just as a missing file or key would.
    const out = try expand(a, "<data.f.k | default \"x\">", null, .{});
    try std.testing.expectEqualStrings("x", out);
    // Without a default it stays a fatal error.
    try std.testing.expectError(error.DataRefWithoutContext, expand(a, "<data.f.k>", null, .{}));
}

fn chainTestState() machine.state.MachineState {
    return .{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "/opt/homebrew",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .env_values = &.{
            .{ .name = "HTTPS_PROXY", .value = "http://proxy:3128" },
            .{ .name = "EMPTYVAR", .value = "" },
        },
    };
}

test "chain: first non-empty env member wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    const out = try expand(arena.allocator(), "proxy = <env.http_proxy | env.HTTPS_PROXY | default \"\">", null, .{ .machine = &m });
    try std.testing.expectEqualStrings("proxy = http://proxy:3128", out);
}

test "chain: falls through empty members to machine field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    const out = try expand(arena.allocator(), "<env.EMPTYVAR | machine.brew_prefix>", null, .{ .machine = &m });
    try std.testing.expectEqualStrings("/opt/homebrew", out);
}

test "chain: exhausted with default emits the default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    const out = try expand(arena.allocator(), "<env.nope | machine.cargo_home | default \"none\">", null, .{ .machine = &m });
    try std.testing.expectEqualStrings("none", out);
}

test "chain: exhausted without default errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    try std.testing.expectError(
        error.UnresolvedFallbackChain,
        expand(arena.allocator(), "<env.nope | machine.cargo_home>", null, .{ .machine = &m }),
    );
}

test "expand: a '>' inside a default does not truncate the capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    // PAGER is not in env_values, so the default (which contains '>') is used.
    const out = try expand(arena.allocator(), "x=<env.PAGER | default \"less >log\">", null, .{ .machine = &m });
    try std.testing.expectEqualStrings("x=less >log", out);
}

test "chain: bare names outside template mode pass through literally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = chainTestState();
    const out = try expand(arena.allocator(), "cat <a | grep b>", null, .{ .machine = &m });
    try std.testing.expectEqualStrings("cat <a | grep b>", out);
}

fn secretTestCtx(m: *const machine.state.MachineState, map: *std.process.Environ.Map, cache: *secret.cache.Cache) Ctx {
    return .{ .io = std.testing.io, .machine = m, .secrets = .{ .env = .{ .map = map }, .cache = cache } };
}

test "expand: inline secret resolves env: mid-line among literal and another capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = chainTestState();
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_INLINE_TOKEN", "hunter2");
    var cache = secret.cache.Cache.init(a);
    const exp = try expandTracked(a, "auth token=<secret:env:MOX_INLINE_TOKEN> on <machine.hostname>", null, secretTestCtx(&m, &map, &cache));
    try std.testing.expectEqualStrings("auth token=hunter2 on h", exp.bytes);
    try std.testing.expect(exp.secret);
}

test "expand: inline secret without a secrets context emits a placeholder, resolving nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The `"` inside the cmd: URI must survive to the placeholder: the capture
    // closes at `>`, not at the quote.
    const exp = try expandTracked(a, "x=<secret:cmd:echo \"a b\">", null, .{});
    try std.testing.expectEqualStrings("x=<SECRET:cmd:echo \"a b\">", exp.bytes);
    try std.testing.expect(!exp.secret);
}

test "expand: inline secret resolution failure is fatal and yields no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = chainTestState();
    var map = std.process.Environ.Map.init(a);
    var cache = secret.cache.Cache.init(a);
    // The env var is absent -> SecretNotFound. There is no resolved value to
    // leak on failure; the compose simply fails.
    try std.testing.expectError(
        error.SecretNotFound,
        expand(a, "token=<secret:env:MOX_DEFINITELY_UNSET_XYZ>", null, secretTestCtx(&m, &map, &cache)),
    );
}

test "isManagerSecretUri: only op:// and pass:// are dedicated-manager schemes" {
    try std.testing.expect(isManagerSecretUri("op://Personal/GitHub/token"));
    try std.testing.expect(isManagerSecretUri("pass://work/signing"));
    try std.testing.expect(!isManagerSecretUri("env:GH_TOKEN"));
    try std.testing.expect(!isManagerSecretUri("file:///etc/hostname"));
    try std.testing.expect(!isManagerSecretUri("cmd:resolve-theme"));
}

test "expand: a resolved non-manager secret does not set the auto-0600 signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = chainTestState();
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_MGR_TEST", "hunter2");
    var cache = secret.cache.Cache.init(a);
    var diag: Diag = .{};
    var ctx = secretTestCtx(&m, &map, &cache);
    ctx.diag = &diag;
    // env: resolves, but (like a cmd:) it is not a manager scheme, so the
    // file is not marked for auto-0600.
    const exp = try expandTracked(a, "t=<secret:env:MOX_MGR_TEST>", null, ctx);
    try std.testing.expect(exp.secret);
    try std.testing.expect(!diag.manager_secret);
}

test "expand: an op:// secret marks the file for auto-0600 (set before resolution)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = chainTestState();
    var map = std.process.Environ.Map.init(a);
    // Bound the (expected-to-fail) op resolution so a stray `op` on PATH cannot
    // stall the test.
    try map.put("MOX_SECRET_TIMEOUT_MS", "500");
    var cache = secret.cache.Cache.init(a);
    var diag: Diag = .{};
    var ctx = secretTestCtx(&m, &map, &cache);
    ctx.diag = &diag;
    // Resolution fails here (no real vault), but the manager-secret flag is set
    // on the resolve path regardless; a failed compose is never written, so the
    // flag is only ever consumed by apply on success.
    _ = expand(a, "k=<secret:op://Vault/Item/field>", null, ctx) catch {};
    try std.testing.expect(diag.manager_secret);
}

test "lint: empty secret uri rejected" {
    try std.testing.expectError(error.EmptySecretUri, lintT("token=<secret:>"));
}

test "lint: secret capture with quotes and pipes is accepted (URI runs to '>')" {
    try lintT("token=<secret:cmd:pass show x | head -1>");
    try lintT("token=<secret:cmd:printf '%s' \"a b\">");
    try lintT("token=<secret:env:GH_TOKEN>");
}

test "lint: an empty-field capture is rejected (lint/expand agreement)" {
    try std.testing.expectError(error.EmptyCaptureName, lintT("x=< | default \"y\">"));
    try std.testing.expectError(error.EmptyCaptureName, lintT("x=<   >"));
}

test "expand: a later capture's default is routed correctly past an earlier capture" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var record = std.StringHashMap(data.value.Value).init(std.testing.allocator);
    defer record.deinit();
    try record.put("a", .{ .string = "A" });
    // The second capture's ` | default "z"` must attach to it, not be mis-scanned
    // from the first capture's position.
    const out = try expand(fba.allocator(), "<entry.a>-<entry.missing | default \"z\">", &record, .{});
    try std.testing.expectEqualStrings("A-z", out);
}

test "lint: secret URI with an escaped '>' is accepted and closes at the unescaped '>'" {
    // The `\>` is a payload byte (a shell redirect), not the capture close.
    try lintT("token=<secret:cmd:echo a 2\\>&1>");
}

test "lint: secret URI whose only '>' is escaped is unclosed" {
    try std.testing.expectError(error.UnclosedCapture, lintT("token=<secret:cmd:echo a 2\\>&1"));
}

test "expand: an escaped '>' does not close the secret capture, and the placeholder keeps it verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The capture closes at the unescaped `>` after `&2`; the trailing `y` is
    // literal. Without escape-aware scanning the capture would close early at
    // the `\>` and `&2>y` would leak into the output.
    const exp = try expandTracked(a, "x=<secret:cmd:echo a 1\\>&2>y", null, .{});
    try std.testing.expectEqualStrings("x=<SECRET:cmd:echo a 1\\>&2>y", exp.bytes);
    try std.testing.expect(!exp.secret);
}

test "unescapeSecretUri: only '\\>' and '\\\\' decode; other bytes are verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2>/dev/null", try unescapeSecretUri(a, "2\\>/dev/null"));
    try std.testing.expectEqualStrings("a\\b", try unescapeSecretUri(a, "a\\\\b"));
    // A lone backslash before an ordinary byte stays literal (both bytes kept).
    try std.testing.expectEqualStrings("printf '\\n'", try unescapeSecretUri(a, "printf '\\n'"));
    // No escapable backslash -> the input slice is returned unchanged.
    const plain = "op://vault/item/field";
    try std.testing.expect((try unescapeSecretUri(a, plain)).ptr == plain.ptr);
}
