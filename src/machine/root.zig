//! Public API for the mox machine module.
pub const state = @import("state.zig");
pub const path_lookup = @import("path_lookup.zig");
pub const bindings = @import("bindings.zig");
pub const facts = @import("facts.zig");
pub const extras = @import("extras.zig");
pub const interview = @import("interview.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = state;
    _ = path_lookup;
    _ = bindings;
    _ = facts;
    _ = extras;
    _ = interview;
}
