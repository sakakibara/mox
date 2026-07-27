const std = @import("std");
const source = @import("../source/root.zig");
const dsl = @import("../dsl/root.zig");

const AxisTuple = source.tree.AxisTuple;
const Overlay = source.tree.Overlay;
const Resolver = dsl.resolver.Resolver;

/// True if every (name=value) pair in `tuple` is satisfied by `resolver`.
///
/// Single-value axes (os, arch, profile, machine, hostname) bind their name directly;
/// multi-value axes (tool, env, path) bind a compound `name=value` key with a
/// sentinel. Overlay filenames need both readings, exactly as directive axis
/// expressions do (`dsl/axis.zig` eqMatch) -- otherwise a `.d/tool=fd` overlay
/// can never match a machine that has fd. Delegates to the resolver's own
/// membership query, so the compound-key iteration lives in exactly one place.
pub fn matches(tuple: AxisTuple, resolver: *const Resolver) bool {
    for (tuple.pairs) |pair| {
        if (!resolver.has(pair.name, pair.value)) return false;
    }
    return true;
}

/// The tuple to match a Cat A/C overlay against: its exact (verbatim
/// filename) reading when that reading is present and satisfies `bindings`,
/// else its extension-stripped reading. An axis value may itself contain a
/// dot (a `hostname` value is the full dotted name, and every macOS hostname
/// ends in `.local`), so an overlay named `hostname=host.local` must match
/// this machine's own `host.local` binding exactly, while `os=darwin.toml`
/// still falls back to `darwin` for editors that want the real extension.
pub fn effectiveOverlayTuple(o: Overlay, resolver: *const Resolver) AxisTuple {
    if (o.exact_tuple) |e| {
        if (matches(e, resolver)) return e;
    }
    return o.tuple;
}

/// Returns the index of the most-specific (longest) matching tuple, or null
/// if none match. Equal-specificity ties are broken by canonical tuple order
/// (`AxisTuple.canonicalLess`), never by slice index, so the winner does not
/// depend on the order overlays were enumerated from the filesystem.
pub fn bestMatch(tuples: []const AxisTuple, resolver: *const Resolver) ?usize {
    var best: ?usize = null;
    for (tuples, 0..) |t, i| {
        if (!matches(t, resolver)) continue;
        if (best) |bi| {
            const b = tuples[bi];
            if (t.pairs.len > b.pairs.len or (t.pairs.len == b.pairs.len and t.canonicalLess(b))) {
                best = i;
            }
        } else {
            best = i;
        }
    }
    return best;
}

test "matches: empty tuple matches everything" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("os", "darwin");
    const t = AxisTuple{ .pairs = &.{} };
    try std.testing.expect(matches(t, &b_r));
}

test "matches: pair must match" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("os", "darwin");
    const t = AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    try std.testing.expect(matches(t, &b_r));
}

test "matches: missing axis fails" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    const t = AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    try std.testing.expect(!matches(t, &b_r));
}

test "bestMatch: longest wins" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("os", "darwin");
    try b.put("profile", "work");

    const tuples = [_]AxisTuple{
        .{ .pairs = &.{} },
        .{ .pairs = &.{.{ .name = "os", .value = "darwin" }} },
        .{ .pairs = &.{ .{ .name = "os", .value = "darwin" }, .{ .name = "profile", .value = "work" } } },
    };
    try std.testing.expectEqual(@as(?usize, 2), bestMatch(&tuples, &b_r));
}

test "bestMatch: no match returns null" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("os", "linux");
    const tuples = [_]AxisTuple{
        .{ .pairs = &.{.{ .name = "os", .value = "darwin" }} },
    };
    try std.testing.expectEqual(@as(?usize, null), bestMatch(&tuples, &b_r));
}

test "matches: multi-value axis overlay matches via the compound key" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("tool=fd", "1"); // this machine has fd (multi-value axis binding)
    const has = AxisTuple{ .pairs = &.{.{ .name = "tool", .value = "fd" }} };
    try std.testing.expect(matches(has, &b_r)); // was silently false before the fix
    const missing = AxisTuple{ .pairs = &.{.{ .name = "tool", .value = "rg" }} };
    try std.testing.expect(!matches(missing, &b_r));
}

test "matches: a multi-value axis with an over-256-byte value still matches" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    const long = "/" ** 300; // e.g. a deep `path=` axis value
    const key = "path=" ++ long;
    try b.put(key, "1");
    const t = AxisTuple{ .pairs = &.{.{ .name = "path", .value = long }} };
    try std.testing.expect(matches(t, &b_r)); // fell through the old 256-byte buffer
}

test "bestMatch: equal-specificity tie is filesystem-order independent" {
    var b = std.StringHashMap([]const u8).init(std.testing.allocator);
    var b_r: Resolver = .{ .live = &.{ .bindings = &b } };
    defer b.deinit();
    try b.put("os", "darwin");
    try b.put("profile", "work");
    const os_t = AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    const prof_t = AxisTuple{ .pairs = &.{.{ .name = "profile", .value = "work" }} };
    // Both match at specificity 1; canonical order puts "os" before "profile",
    // so os wins no matter which order the overlays were enumerated in.
    const forward = [_]AxisTuple{ os_t, prof_t };
    const reverse = [_]AxisTuple{ prof_t, os_t };
    try std.testing.expectEqualStrings("os", forward[bestMatch(&forward, &b_r).?].pairs[0].name);
    try std.testing.expectEqualStrings("os", reverse[bestMatch(&reverse, &b_r).?].pairs[0].name);
}
