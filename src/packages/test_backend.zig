//! A stub backend for the core's own tests.
//!
//! Its ids mirror brew's two namespaces so the collision a raw-name
//! comparison would miss is exercised without depending on a real adapter.
//! Only `name` and `idOf` answer; every other operation is unreachable, so a
//! test that strays into one fails instead of reading a default.

const std = @import("std");

const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

const Backend = backend_mod.Backend;
const Row = manifest_mod.Row;

pub fn make(name: []const u8) Backend {
    return .{ .name = name, .ctx = undefined, .vtable = &vtable };
}

const vtable: Backend.VTable = .{
    .available = unreachedAvailable,
    .validate = validate,
    .idOf = idOf,
    .installedExplicit = unreachedInstalled,
    .install = unreachedInstall,
};

fn idOf(_: *anyopaque, arena: std.mem.Allocator, row: Row) anyerror![]const u8 {
    const f = row.field("kind") orelse return row.name;
    const s = switch (f) {
        .string => |v| v,
        else => return row.name,
    };
    if (!std.mem.eql(u8, s, "cask")) return row.name;
    return std.fmt.allocPrint(arena, "cask:{s}", .{row.name});
}

fn validate(_: *anyopaque, _: Row, _: ?*manifest_mod.Diag) anyerror!void {}

fn unreachedAvailable(_: *anyopaque, _: std.mem.Allocator) anyerror!bool {
    return error.Unreached;
}
fn unreachedInstalled(_: *anyopaque, _: std.mem.Allocator) anyerror![]const []const u8 {
    return error.Unreached;
}
fn unreachedInstall(_: *anyopaque, _: std.mem.Allocator, _: []const Row) anyerror!void {
    return error.Unreached;
}
