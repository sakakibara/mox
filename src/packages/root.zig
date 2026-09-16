//! Public API for the mox package subsystem: the `data/packages/*.toml`
//! manifest, and (as they land) the backend adapters, drift computation, and
//! reconcile orchestration built on it.
pub const manifest = @import("manifest.zig");
pub const desired = @import("desired.zig");
pub const drift = @import("drift.zig");
pub const exec = @import("exec.zig");
pub const backend = @import("backend.zig");
pub const brew = @import("brew.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = manifest;
    _ = desired;
    _ = drift;
    _ = exec;
    _ = backend;
    _ = brew;
}
