//! Public API for the mox apply module.
pub const write = @import("write.zig");
pub const run_scripts = @import("run_scripts.zig");
pub const applied = @import("applied.zig");
pub const snapshot = @import("snapshot.zig");
pub const exact = @import("exact.zig");
pub const generated = @import("generated.zig");
pub const drift = @import("drift.zig");
pub const partial = @import("partial.zig");
pub const canonical = @import("canonical.zig");
pub const owned = @import("owned.zig");
pub const mox_path = @import("mox_path.zig");
pub const stale = @import("stale.zig");
pub const parent_link = @import("parent_link.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = write;
    _ = run_scripts;
    _ = applied;
    _ = snapshot;
    _ = exact;
    _ = generated;
    _ = drift;
    _ = partial;
    _ = canonical;
    _ = owned;
    _ = mox_path;
    _ = stale;
    _ = parent_link;
}
