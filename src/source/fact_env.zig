//! Shared fact-name <-> environment-variable projection: `apply.run_scripts`
//! uses it to build a setup script's `MOX_FACT_<NAME>` environment, and
//! `machine.dimensions` uses the identical projection to match a scanned
//! `MOX_FACT_<NAME>` token back to the fact name that would produce it. One
//! function, so the two can never drift apart.

const std = @import("std");

/// Project a fact name onto its `MOX_FACT_<NAME>` environment token: each
/// alphanumeric byte uppercased, everything else becomes `_`.
pub fn envName(arena: std.mem.Allocator, name: []const u8) ![]u8 {
    const prefix = "MOX_FACT_";
    const out = try arena.alloc(u8, prefix.len + name.len);
    @memcpy(out[0..prefix.len], prefix);
    for (name, 0..) |c, i| {
        out[prefix.len + i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
    }
    return out;
}

fn isAsciiName(name: []const u8) bool {
    for (name) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

/// Which of `names` project onto a distinct, unambiguous `MOX_FACT_<NAME>`
/// token: excludes a non-ASCII name (a byte >= 0x80 can only sanitize to `_`,
/// destroying the name) and any name whose projection collides with another
/// name's (both excluded, since keeping either would silently pick one by
/// iteration order). The returned map holds only the names that survive,
/// each to its token; `.get(name) == null` means the name is skipped.
pub fn project(arena: std.mem.Allocator, names: []const []const u8) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(arena);

    var counts = std.StringHashMap(usize).init(arena);
    const encoded = try arena.alloc(?[]const u8, names.len);
    for (names, 0..) |n, i| {
        if (!isAsciiName(n)) {
            encoded[i] = null;
            continue;
        }
        const enc = try envName(arena, n);
        encoded[i] = enc;
        const gop = try counts.getOrPut(enc);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    for (names, 0..) |n, i| {
        const enc = encoded[i] orelse continue;
        if (counts.get(enc).? > 1) continue;
        try result.put(n, enc);
    }
    return result;
}

test "envName: non-identifier characters become underscores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("MOX_FACT_GDRIVE_ACCOUNT", try envName(arena.allocator(), "gdrive.account"));
}

test "project: a plain name projects to its token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{"profile"};
    const projected = try project(a, &names);
    try std.testing.expectEqualStrings("MOX_FACT_PROFILE", projected.get("profile").?);
}

test "project: a non-ASCII name has no token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"};
    const projected = try project(a, &names);
    try std.testing.expect(projected.get(names[0]) == null);
}

test "project: two names that sanitize identically both have no token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{ "cloud.backend", "cloud-backend", "profile" };
    const projected = try project(a, &names);
    try std.testing.expect(projected.get("cloud.backend") == null);
    try std.testing.expect(projected.get("cloud-backend") == null);
    try std.testing.expectEqualStrings("MOX_FACT_PROFILE", projected.get("profile").?);
}
