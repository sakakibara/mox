//! Public API for the mox data module (data sources for for-loops).
pub const value = @import("value.zig");
pub const toml = @import("toml.zig");
pub const toml_statements = @import("toml_statements.zig");
pub const source = @import("source.zig");

test {
    _ = toml_statements;
}
