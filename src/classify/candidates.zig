//! Candidate computation and post-write verification for `mox commit`
//! classification.
//!
//! When a shared-origin (base / universal fragment) hunk affects only a
//! subset of the configuration space, commit prompts the user to choose
//! where the edit should live. `compute` builds the ordered candidate list
//! the prompt renders; the design orders them universal-first, then the
//! axes the source COMPARES BY VALUE, then the in-repo machine-local
//! overlay, then the never-committed private layer. An axis only ever
//! tested for presence is not a classification, so it can never be offered
//! as a candidate and its value never reaches a label. `firstViolation` is
//! the post-write guard: after routing, no sibling configuration may compose
//! differently than it did before unless the user chose to affect it.

const std = @import("std");
const source = @import("../source/root.zig");
const config_space = @import("config_space.zig");

const Axes = source.axes.Axes;
const Configuration = config_space.Configuration;

pub const Kind = enum { universal, axis, machine_local, private };

pub const Candidate = struct {
    kind: Kind,
    /// Human label: "" for universal / machine_local / private, "os=darwin"
    /// for axis.
    label: []const u8 = "",
    /// For `.axis`: the axis name.
    axis_name: []const u8 = "",
    /// For `.axis`: this machine's value on that axis.
    axis_value: []const u8 = "",
};

const AxisEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Build the ordered candidate list for a shared-origin hunk on this machine.
///
/// `this_bindings` is this machine's evaluation bindings; a single-value axis
/// becomes an axis candidate only when the source compares it against a
/// value (`ax.comparesValueOf`) -- an axis merely tested for presence is not
/// a classification and must never be offered.
pub fn compute(
    arena: std.mem.Allocator,
    this_bindings: *const std.StringHashMap([]const u8),
    ax: Axes,
) ![]const Candidate {
    var axes: std.ArrayList(AxisEntry) = .empty;

    var it = this_bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // Compound presence keys (tool=/env=/path=) are never single-axis
        // synthesis targets; the built-in `machine` axis is offered separately.
        if (std.mem.indexOfScalar(u8, name, '=') != null) continue;
        if (std.mem.eql(u8, name, "machine")) continue;
        if (!ax.comparesValueOf(name)) continue;

        try axes.append(arena, .{ .name = name, .value = entry.value_ptr.* });
    }

    std.mem.sort(AxisEntry, axes.items, {}, struct {
        fn lt(_: void, a: AxisEntry, b: AxisEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var out: std.ArrayList(Candidate) = .empty;
    try out.append(arena, .{ .kind = .universal });
    for (axes.items) |e| {
        try out.append(arena, .{
            .kind = .axis,
            .label = try std.fmt.allocPrint(arena, "{s}={s}", .{ e.name, e.value }),
            .axis_name = e.name,
            .axis_value = e.value,
        });
    }
    try out.append(arena, .{ .kind = .machine_local });
    try out.append(arena, .{ .kind = .private });
    return out.toOwnedSlice(arena);
}

/// Index of the first sibling configuration whose composed output changed
/// between the pre-write `baseline` and post-write `after` snapshots yet was
/// NOT among the labels the user chose to affect, or null when every change
/// was intended. Both slices are index-aligned with `configs`; a null entry
/// means the file is gated off for that configuration.
pub fn firstViolation(
    configs: []const Configuration,
    baseline: []const ?[]const u8,
    after: []const ?[]const u8,
    allowed: *const std.StringHashMap(void),
) ?usize {
    for (configs, 0..) |cfg, i| {
        if (cfg.is_this_machine) continue;
        if (allowed.contains(cfg.label)) continue;
        if (differs(baseline[i], after[i])) return i;
    }
    return null;
}

fn differs(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return false;
    if (a == null or b == null) return true;
    return !std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

test "compute: offers an axis compared by value, never a fact tested for presence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    try this.put("signing_key", "ssh-ed25519 SECRET");

    var ax: source.axes.Axes = .{
        .names = std.StringHashMap(void).init(a),
        .values = std.StringHashMap(void).init(a),
        .compared = std.StringHashMap(void).init(a),
        .valuesOf = std.StringHashMap(std.ArrayList(source.axes.Value)).init(a),
    };
    try ax.names.put("os", {});
    try ax.compared.put("os", {});
    try ax.names.put("signing_key", {}); // presence only

    const got = try compute(a, &this, ax);

    var saw_os = false;
    for (got) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.axis_name, "signing_key"));
        try std.testing.expect(std.mem.indexOf(u8, c.label, "SECRET") == null);
        if (std.mem.eql(u8, c.axis_name, "os")) saw_os = true;
    }
    try std.testing.expect(saw_os);
    try std.testing.expectEqual(Kind.universal, got[0].kind); // universal first
}

test "compute: universal first, axis candidates by name, then machine_local, then private" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this_b = std.StringHashMap([]const u8).init(a);
    try this_b.put("os", "darwin");
    try this_b.put("profile", "personal");
    try this_b.put("machine", "mbp");
    try this_b.put("tool=fd", "1");

    var ax: Axes = .{
        .names = std.StringHashMap(void).init(a),
        .values = std.StringHashMap(void).init(a),
        .compared = std.StringHashMap(void).init(a),
        .valuesOf = std.StringHashMap(std.ArrayList(source.axes.Value)).init(a),
    };
    try ax.names.put("os", {});
    try ax.compared.put("os", {});
    try ax.names.put("profile", {});
    try ax.compared.put("profile", {});

    const cands = try compute(a, &this_b, ax);

    // universal, os=darwin, profile=personal (alphabetical), machine, private.
    // Neither the compound tool= key nor the built-in machine axis is offered
    // as its own axis candidate.
    try testing.expectEqual(@as(usize, 5), cands.len);
    try testing.expectEqual(Kind.universal, cands[0].kind);
    try testing.expectEqual(Kind.axis, cands[1].kind);
    try testing.expectEqualStrings("os", cands[1].axis_name);
    try testing.expectEqualStrings("os=darwin", cands[1].label);
    try testing.expectEqual(Kind.axis, cands[2].kind);
    try testing.expectEqualStrings("profile", cands[2].axis_name);
    try testing.expectEqualStrings("profile=personal", cands[2].label);
    try testing.expectEqual(Kind.machine_local, cands[3].kind);
    try testing.expectEqual(Kind.private, cands[4].kind);
}

test "firstViolation: flags a changed unaffected configuration, ignores allowed ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c0 = Configuration{ .label = "aaaa0000", .bindings = std.StringHashMap([]const u8).init(a), .is_this_machine = false };
    const c1 = Configuration{ .label = "bbbb0001", .bindings = std.StringHashMap([]const u8).init(a), .is_this_machine = false };
    const configs = [_]Configuration{ c0, c1 };

    const baseline = [_]?[]const u8{ "x\n", "y\n" };
    // c0 changed and is NOT allowed -> violation at index 0.
    const after = [_]?[]const u8{ "x-edited\n", "y\n" };

    var allowed = std.StringHashMap(void).init(a);
    try testing.expectEqual(@as(?usize, 0), firstViolation(&configs, &baseline, &after, &allowed));

    // Once c0 is allowed to change, no violation remains.
    try allowed.put("aaaa0000", {});
    try testing.expectEqual(@as(?usize, null), firstViolation(&configs, &baseline, &after, &allowed));
}
