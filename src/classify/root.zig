//! Public API for the mox classify module (G/G' classification).
pub const impact = @import("impact.zig");
pub const candidates = @import("candidates.zig");
pub const synth = @import("synth.zig");
pub const config_space = @import("config_space.zig");

test {
    _ = impact;
    _ = candidates;
    _ = synth;
    _ = config_space;
}
