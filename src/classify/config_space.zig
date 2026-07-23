//! The configuration space a file's own directives express.
//!
//! A configuration is a point in that space: this machine's bindings, with the
//! compared axes overridden. Simulating an edit against every configuration is
//! strictly stronger than simulating it against a census of machines -- a
//! machine is one instance of a configuration, and the source is never stale.
//!
//! A fact the source only tests for presence never varies here. It is not a
//! classification; it is evaluated from this machine's own facts, and it never
//! reaches a label.

const std = @import("std");
const source = @import("../source/root.zig");

pub const Configuration = struct {
    /// Human label: "" for this machine's own, else "os=linux" / "os=linux+profile=work".
    label: []const u8,
    /// Full evaluation bindings: this machine's, with the space's axes overridden.
    bindings: std.StringHashMap([]const u8),
    /// True for the configuration matching this machine.
    is_this_machine: bool,
};

pub fn enumerate(
    arena: std.mem.Allocator,
    this_bindings: *const std.StringHashMap([]const u8),
    ax: source.axes.Axes,
    /// Axis names for which the unbound (`null`) representative must be
    /// enumerated even when this machine binds the axis -- e.g. a fall-through
    /// sibling that leaves an optional fact unset. Every other axis keeps the
    /// original rule (`null` appears only when this machine is itself
    /// unbound). Pass `&.{}` to preserve that original rule for every axis.
    force_unbound: []const []const u8,
    /// Axis names for which a representative of every value the sources do NOT
    /// name must be enumerated -- an axis every machine binds, but to a value
    /// this repo may never have mentioned (a Linux box for a tree that only
    /// names `os=darwin`). One representative is sound AND complete because
    /// every axis test is exact equality against a named literal: two unnamed
    /// values are therefore indistinguishable to every directive, so they
    /// compose identically and one stands for all. Note this is NOT the same as
    /// composing only the base -- a negated test (`when not os=darwin`) is
    /// ENABLED here, which is exactly the behaviour such a machine gets.
    /// Labelled `name=(other)`.
    force_other: []const []const u8,
) ![]Configuration {
    // The axes the source compares, sorted for a stable label and a stable test.
    var compared: std.ArrayList([]const u8) = .empty;
    var it = ax.compared.keyIterator();
    while (it.next()) |n| try compared.append(arena, n.*);
    std.mem.sort([]const u8, compared.items, {}, lessThan);

    // Each axis's value set: what the source names, plus this machine's own --
    // or `null` if this machine has no value for the axis at all. `null` is a
    // first-class member, not the empty string: it means "unbound", so a
    // materialized configuration leaves the axis out of bindings entirely.
    // An axis whose only value is this machine's own does not VARY, so it is no
    // dimension of the space: it is dropped from `names` below.
    var names: std.ArrayList([]const u8) = .empty;
    var value_sets: std.ArrayList([]const ?[]const u8) = .empty;
    // Per dimension, the synthetic stand-in for "a value no source names", or
    // null when the dimension has none. Only its label differs: it binds like
    // any other value, and matches no overlay by construction.
    var others: std.ArrayList(?[]const u8) = .empty;
    for (compared.items) |name| {
        var vals: std.ArrayList([]const u8) = .empty;
        const mine = this_bindings.get(name);
        for (ax.valuesFor(name)) |v| {
            // A fragment filename that carries a suffix names two candidate
            // values (`host.local` is `machine=host.local` or `machine=host`
            // plus an extension). This machine's own binding settles which,
            // exactly as compose does when it resolves the fragment.
            const resolved = if (v.exact) |e|
                (if (mine != null and std.mem.eql(u8, mine.?, e)) e else v.value)
            else
                v.value;
            if (!contains(vals.items, resolved)) try vals.append(arena, resolved);
        }
        if (mine) |m| {
            if (!contains(vals.items, m)) try vals.append(arena, m);
        }
        std.mem.sort([]const u8, vals.items, {}, lessThan);

        var opt_vals: std.ArrayList(?[]const u8) = .empty;
        for (vals.items) |v| try opt_vals.append(arena, v);
        if (mine == null or contains(force_unbound, name)) try opt_vals.append(arena, null);
        var other_val: ?[]const u8 = null;
        if (contains(force_other, name)) {
            other_val = try unusedValue(arena, vals.items);
            try opt_vals.append(arena, other_val.?);
        }
        // A lone value is necessarily this machine's own (an unbound axis always
        // contributes `null` as a second member): nothing to enumerate.
        if (opt_vals.items.len == 1) continue;
        try names.append(arena, name);
        try value_sets.append(arena, opt_vals.items);
        try others.append(arena, other_val);
    }

    var out: std.ArrayList(Configuration) = .empty;
    const idx = try arena.alloc(usize, names.items.len);
    @memset(idx, 0);

    while (true) {
        var bindings = try this_bindings.clone();
        var label: std.ArrayList(u8) = .empty;
        var is_this = true;

        for (names.items, 0..) |name, i| {
            const value = value_sets.items[i][idx[i]];
            const mine_here = this_bindings.get(name);
            if (value) |v| {
                try bindings.put(name, v);
                if (label.items.len != 0) try label.append(arena, '+');
                try label.appendSlice(arena, name);
                if (others.items[i] != null and std.mem.eql(u8, v, others.items[i].?)) {
                    // The synthetic value is an implementation detail; naming it
                    // bare would read as a real machine value the user could
                    // look up. `unusedValue` reserved this parenthesized form
                    // too, so it cannot collide with a real value's label.
                    try label.print(arena, "=({s})", .{v});
                } else {
                    try label.append(arena, '=');
                    try label.appendSlice(arena, v);
                }
            } else {
                // `bindings` started as a clone of THIS machine's bindings, so
                // an unbound axis must be explicitly dropped -- otherwise a
                // `force_unbound` sibling (mine_here != null) would silently
                // keep composing under this machine's own value instead of
                // simulating a real fall-through. A no-op when mine_here is
                // itself null, since the clone never had the key.
                _ = bindings.remove(name);
                if (mine_here != null) {
                    // This machine binds the axis but this configuration
                    // falls through (a `force_unbound` sibling): mark it
                    // explicitly, or an omitted segment would read
                    // identically to this machine's own "" label. Without
                    // `force_unbound` a `null` value only ever arises when
                    // `mine_here` is itself null, so this branch is
                    // unreachable for any existing caller.
                    if (label.items.len != 0) try label.append(arena, '+');
                    try label.appendSlice(arena, name);
                    try label.appendSlice(arena, "=(unset)");
                }
            }

            if (!optEql(mine_here, value)) is_this = false;
        }

        // A configuration other than this machine's IS another machine, so it
        // cannot carry this machine's hostname: leaving `machine` bound to it
        // makes a machine-local region ("only here") resolve in every sibling,
        // which is the opposite of what it means. When `machine` is one of the
        // varying axes the odometer has already given it that configuration's
        // own value, so only an inherited binding is dropped.
        if (!is_this and !contains(names.items, "machine")) _ = bindings.remove("machine");

        // The same rule as a filter, for when `machine` IS a varying axis: the
        // odometer pairs every machine value with every other axis's values,
        // and this machine's own hostname combined with a sibling's value on
        // another axis names a machine that cannot exist. Enumerating it would
        // put a duplicate, impossible row in a blast-radius confirm.
        const impossible_self = !is_this and contains(names.items, "machine") and blk: {
            const mine_machine = this_bindings.get("machine") orelse break :blk false;
            const here = bindings.get("machine") orelse break :blk false;
            break :blk std.mem.eql(u8, here, mine_machine);
        };

        if (!impossible_self) {
            try out.append(arena, .{
                .label = if (is_this) "" else try label.toOwnedSlice(arena),
                .bindings = bindings,
                .is_this_machine = is_this,
            });
        }

        if (names.items.len == 0) break;
        if (!advance(idx, value_sets.items)) break;
    }
    return out.toOwnedSlice(arena);
}

/// Odometer step over the value sets. False when it wraps to the start.
fn advance(idx: []usize, sets: []const []const ?[]const u8) bool {
    var i = idx.len;
    while (i > 0) {
        i -= 1;
        idx[i] += 1;
        if (idx[i] < sets[i].len) return true;
        idx[i] = 0;
    }
    return false;
}

/// A value no source names, so no overlay can match it. Built by extending
/// "other" until BOTH it and its parenthesized label form fall outside `vals`
/// (the axis's whole named value set). The label matters as much as the value:
/// labels key the guard's `allowed` set, so a source naming the literal value
/// `(other)` would otherwise produce two configurations indistinguishable to
/// it, and allowing one would allow the other.
fn unusedValue(arena: std.mem.Allocator, vals: []const []const u8) ![]const u8 {
    var candidate: []const u8 = "other";
    while (contains(vals, candidate) or
        contains(vals, try std.fmt.allocPrint(arena, "({s})", .{candidate})))
    {
        candidate = try std.fmt.allocPrint(arena, "{s}_", .{candidate});
    }
    return candidate;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Unset (`null`) compares equal only to unset; a real value compares by content.
fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "enumerate: force_other adds one unnamed-value representative per axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");

    // The tree names only this machine's own os, so without `force_other` the
    // axis does not vary and the space is a single point -- the blind spot a
    // promote to the base would slip through.
    const ax = try axesFixture(a, &.{.{ "os", "darwin" }}, &.{});

    try std.testing.expectEqual(@as(usize, 1), (try enumerate(a, &this, ax, &.{}, &.{})).len);

    const configs = try enumerate(a, &this, ax, &.{}, &.{"os"});
    try std.testing.expectEqual(@as(usize, 2), configs.len);
    var saw_other = false;
    for (configs) |c| {
        if (std.mem.eql(u8, c.label, "os=(other)")) {
            saw_other = true;
            try std.testing.expect(!c.is_this_machine);
            // It binds a real value -- one no source names, so no overlay matches.
            try std.testing.expect(!std.mem.eql(u8, c.bindings.get("os").?, "darwin"));
        }
    }
    try std.testing.expect(saw_other);
}

test "enumerate: never pairs this machine's hostname with a sibling configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    try this.put("machine", "host-a");

    const ax = try axesFixture(a, &.{ .{ "os", "darwin" }, .{ "machine", "host-a" } }, &.{});
    const configs = try enumerate(a, &this, ax, &.{}, &.{ "os", "machine" });

    // `machine=host-a+os=(other)` is not a machine that can exist: host-a IS
    // this machine, and this machine's os is darwin.
    for (configs) |c| {
        if (c.is_this_machine) continue;
        const m = c.bindings.get("machine") orelse continue;
        try std.testing.expect(!std.mem.eql(u8, m, "host-a"));
    }
}

test "enumerate: varies only axes the source compares by value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "linux");
    try this.put("signing_key", "ssh-ed25519 SECRET"); // a fact, present
    try this.put("email", "me@example.com"); // a fact, interpolation only

    const ax = try axesFixture(a, &.{ .{ "os", "darwin" }, .{ "os", "linux" } }, &.{"signing_key"});

    const configs = try enumerate(a, &this, ax, &.{}, &.{});

    // os=darwin and os=linux. Nothing else varies.
    try std.testing.expectEqual(@as(usize, 2), configs.len);

    var saw_darwin = false;
    var saw_this = false;
    for (configs) |c| {
        if (std.mem.eql(u8, c.label, "os=darwin")) saw_darwin = true;
        if (c.is_this_machine) {
            saw_this = true;
            try std.testing.expectEqualStrings("linux", c.bindings.get("os").?);
        }
        // The fact travels into every configuration unchanged: composition still
        // interpolates it, and its presence still gates.
        try std.testing.expectEqualStrings("ssh-ed25519 SECRET", c.bindings.get("signing_key").?);
        try std.testing.expectEqualStrings("me@example.com", c.bindings.get("email").?);
        // A fact is never part of a configuration's identity.
        try std.testing.expect(std.mem.indexOf(u8, c.label, "signing_key") == null);
    }
    try std.testing.expect(saw_darwin);
    try std.testing.expect(saw_this);
}

test "enumerate: two compared axes produce their cross product" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    try this.put("profile", "personal");

    const ax = try axesFixture(a, &.{
        .{ "os", "darwin" },    .{ "os", "linux" },
        .{ "profile", "work" }, .{ "profile", "personal" },
    }, &.{});

    const configs = try enumerate(a, &this, ax, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 4), configs.len);
}

test "enumerate: a file naming no axis yields exactly this machine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");

    const ax = try axesFixture(a, &.{}, &.{});
    const configs = try enumerate(a, &this, ax, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), configs.len);
    try std.testing.expect(configs[0].is_this_machine);
    try std.testing.expectEqualStrings("", configs[0].label);
}

test "enumerate: an axis unset on this machine still yields exactly one match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This machine has no "profile" fact at all -- only "os".
    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");

    const ax = try axesFixture(a, &.{
        .{ "profile", "work" },
        .{ "os", "darwin" },
    }, &.{});

    const configs = try enumerate(a, &this, ax, &.{}, &.{});

    var this_count: usize = 0;
    var this_config: ?Configuration = null;
    for (configs) |c| {
        if (c.is_this_machine) {
            this_count += 1;
            this_config = c;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), this_count);

    const c = this_config.?;
    try std.testing.expect(c.bindings.get("profile") == null);
    try std.testing.expect(std.mem.indexOf(u8, c.label, "profile") == null);
}

/// `compared` is (axis, value) pairs the source compares; `presence` is names it
/// only tests for existence.
fn axesFixture(
    a: std.mem.Allocator,
    compared: []const [2][]const u8,
    presence: []const []const u8,
) !source.axes.Axes {
    var ax: source.axes.Axes = .{
        .names = std.StringHashMap(void).init(a),
        .values = std.StringHashMap(void).init(a),
        .compared = std.StringHashMap(void).init(a),
        .valuesOf = std.StringHashMap(std.ArrayList(source.axes.Value)).init(a),
    };
    for (compared) |pair| {
        try ax.names.put(pair[0], {});
        try ax.compared.put(pair[0], {});
        const gop = try ax.valuesOf.getOrPut(pair[0]);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{ .value = pair[1] });
    }
    for (presence) |n| try ax.names.put(n, {});
    return ax;
}
