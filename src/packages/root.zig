//! Public API for the mox package subsystem: the `data/packages/*.toml`
//! manifest, and (as they land) the backend adapters, drift computation, and
//! reconcile orchestration built on it.
pub const manifest = @import("manifest.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = manifest;
}
