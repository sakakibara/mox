//! Public API for the mox compose module.
pub const match = @import("match.zig");
pub const category = @import("category.zig");
pub const pacifier = @import("pacifier.zig");
pub const catA = @import("catA.zig");
pub const catB = @import("catB.zig");
pub const catC = @import("catC.zig");
pub const interp = @import("interp.zig");
pub const toml_merge = @import("toml_merge.zig");
pub const json_merge = @import("json_merge.zig");
pub const yaml_merge = @import("yaml_merge.zig");
pub const ini_merge = @import("ini_merge.zig");
pub const composeFile = @import("compose.zig").composeFile;
pub const composeFileTracked = @import("compose.zig").composeFileTracked;

test {
    // Force test discovery in submodules whose `pub const` re-export above
    // doesn't get walked at comptime by `zig build test` alone.
    _ = toml_merge;
    _ = json_merge;
    _ = yaml_merge;
    _ = ini_merge;
}
