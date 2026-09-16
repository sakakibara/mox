//! Public API for the mox package subsystem: the `data/packages/*.toml`
//! manifest, and (as they land) the backend adapters, drift computation, and
//! reconcile orchestration built on it.
pub const manifest = @import("manifest.zig");
pub const desired = @import("desired.zig");
pub const drift = @import("drift.zig");
pub const exec = @import("exec.zig");
pub const backend = @import("backend.zig");
pub const validate = @import("validate.zig");
pub const brew = @import("brew.zig");
pub const linux = @import("linux.zig");
pub const windows = @import("windows.zig");
pub const zypper = @import("zypper.zig");
pub const ledger = @import("ledger.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const plugin = @import("plugin.zig");
pub const discover = @import("discover.zig");
pub const report = @import("report.zig");
pub const write = @import("write.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = manifest;
    _ = desired;
    _ = drift;
    _ = exec;
    _ = backend;
    _ = validate;
    _ = brew;
    _ = linux;
    _ = windows;
    _ = zypper;
    _ = ledger;
    _ = bootstrap;
    _ = plugin;
    _ = discover;
    _ = report;
    _ = write;
}
