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

/// The same stub for a manager that ships an installer, so a test about
/// `[[bootstrap]]` rows is not answered by "this one ships with the OS".
pub fn makeBootstrappable(name: []const u8) Backend {
    return .{ .name = name, .ctx = undefined, .vtable = &bootstrappable_vtable };
}

const vtable: Backend.VTable = .{
    .available = unreachedAvailable,
    .validate = validate,
    .idOf = idOf,
    .installedExplicit = unreachedInstalled,
    .install = unreachedInstall,
    .declare = declare,
};

const bootstrappable_vtable: Backend.VTable = .{
    .available = unreachedAvailable,
    .validate = validate,
    .idOf = idOf,
    .installedExplicit = unreachedInstalled,
    .install = unreachedInstall,
    .declare = declare,
    .bootstrap = unreachedBootstrap,
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

fn declare(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!backend_mod.Backend.Declaration {
    if (std.mem.startsWith(u8, id, "cask:")) {
        return .{
            .name = id["cask:".len..],
            .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        };
    }
    return .{ .name = id };
}

fn unreachedAvailable(_: *anyopaque, _: std.mem.Allocator) anyerror!Backend.Availability {
    return error.Unreached;
}
fn unreachedInstalled(_: *anyopaque, _: std.mem.Allocator) anyerror![]const []const u8 {
    return error.Unreached;
}
fn unreachedInstall(_: *anyopaque, _: std.mem.Allocator, _: []const Row) anyerror!void {
    return error.Unreached;
}
fn unreachedBootstrap(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]const u8 {
    return error.Unreached;
}
