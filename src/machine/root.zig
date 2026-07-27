//! Public API for the mox machine module.
pub const state = @import("state.zig");
pub const path_lookup = @import("path_lookup.zig");
pub const bindings = @import("bindings.zig");
pub const facts = @import("facts.zig");
pub const derived_facts = @import("derived_facts.zig");
pub const path_registry = @import("path_registry.zig");
pub const diag = @import("diag.zig");
pub const interview = @import("interview.zig");
pub const dimensions = @import("dimensions.zig");

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = state;
    _ = path_lookup;
    _ = bindings;
    _ = facts;
    _ = derived_facts;
    _ = path_registry;
    _ = diag;
    _ = interview;
    _ = dimensions;
}
