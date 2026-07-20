//! Public API for the mox coupling module (F: cross-file coupling).
pub const tokens = @import("tokens.zig");
pub const graph = @import("graph.zig");
pub const index = @import("index.zig");
pub const decline = @import("decline.zig");
pub const divergence = @import("divergence.zig");
pub const store = @import("store.zig");

test {
    _ = store;
}
