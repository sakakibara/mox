const std = @import("std");
const source = @import("../source/root.zig");
const match_mod = @import("match.zig");
const machine = @import("../machine/root.zig");

const Io = std.Io;
const ManagedFile = source.tree.ManagedFile;
const AxisTuple = source.tree.AxisTuple;

pub const ComposeError = error{
    NoMatchingOverlay,
};

const max_file_bytes: usize = 256 * 1024 * 1024;

/// Compose a Category C managed file. Returns the bytes that should be
/// written to the live path; memory is owned by `arena`.
///
/// Picks the most-specific overlay tuple matching `bindings`. When
/// `has_base` is true, the base file is treated as an implicit
/// universal overlay. Returns `error.NoMatchingOverlay` when no overlay
/// (and no base) matches.
pub fn compose(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    _: ?*const machine.state.MachineState,
    /// Set to whether the winning layer is the base, for provenance: a Cat C
    /// file's bytes come from exactly ONE layer, and which one it is cannot be
    /// inferred from whether the file DECLARES overlays -- an overlay that does
    /// not match this machine contributes nothing.
    from_base: ?*bool,
) !?[]u8 {
    var candidates: std.ArrayList(AxisTuple) = .empty;
    defer candidates.deinit(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(arena);

    if (file.has_base) {
        try candidates.append(arena, .{ .pairs = &.{} });
        try paths.append(arena, file.source_base_abs);
    }
    for (file.overlays) |o| {
        try candidates.append(arena, match_mod.effectiveOverlayTuple(o, bindings));
        try paths.append(arena, o.path);
    }

    const idx = match_mod.bestMatch(candidates.items, bindings) orelse return null;
    if (from_base) |fb| fb.* = file.has_base and idx == 0;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, paths.items[idx], arena, .limited(max_file_bytes));
    return bytes;
}
