//! The contract every package manager is reached through.
//!
//! The core knows only these five operations. Everything a manager needs
//! beyond them -- which keys its rows accept, which executable proves it is
//! installed, how a qualified name is spelled -- is the adapter's, so adding
//! a manager never edits the core and a manager's own churn never leaves its
//! adapter.

const std = @import("std");

const manifest_mod = @import("manifest.zig");

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;

/// Every adapter mox knows, whether or not this machine can use it. A row
/// naming something outside it is a typo, not a machine difference, so the
/// two are never the same branch.
pub const Registry = struct {
    backends: []const Backend,

    pub fn find(self: Registry, name: []const u8) ?Backend {
        for (self.backends) |b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    pub fn has(self: Registry, name: []const u8) bool {
        return self.find(name) != null;
    }
};

pub const Backend = struct {
    /// The `backend = "..."` spelling a manifest row selects this adapter by.
    name: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,
    /// What this adapter structurally cannot see, in one line, or null when
    /// it can answer everything asked of it. A manager with no
    /// explicitly-installed query cannot report a package the user installed
    /// by hand, and reporting nothing is indistinguishable from reporting
    /// that there is nothing -- so the gap is stated rather than left to be
    /// discovered.
    limitation: ?[]const u8 = null,

    pub const VTable = struct {
        /// Whether this manager is usable on this machine.
        available: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror!bool,
        /// Reject a row this adapter cannot act on: an unknown key, a missing
        /// required one, a value outside the accepted set.
        validate: *const fn (ctx: *anyopaque, row: Row, diag: ?*Diag) anyerror!void,
        /// The id this row is known by, in the same namespace
        /// `installedExplicit` reports. Two rows the manager keeps apart must
        /// not collapse to one id.
        idOf: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, row: Row) anyerror![]const u8,
        /// What the user installed on purpose, never a dependency pulled in
        /// behind one.
        installedExplicit: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8,
        /// Install these rows, leaving resolution to the manager.
        install: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void,
        /// The row that would name an observed installed id: the inverse of
        /// `idOf`, for writing a hand-installed package back into the
        /// manifest. `idOf` of the result must equal the id given.
        declare: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!Declaration,
    };

    /// What a reconciled row says: the `name` a manifest row carries, plus
    /// whichever adapter fields identify it.
    pub const Declaration = struct {
        name: []const u8,
        fields: []const manifest_mod.Pair = &.{},
    };

    pub fn available(self: Backend, arena: std.mem.Allocator) anyerror!bool {
        return self.vtable.available(self.ctx, arena);
    }

    pub fn validate(self: Backend, row: Row, diag: ?*Diag) anyerror!void {
        return self.vtable.validate(self.ctx, row, diag);
    }

    pub fn idOf(self: Backend, arena: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return self.vtable.idOf(self.ctx, arena, row);
    }

    pub fn installedExplicit(self: Backend, arena: std.mem.Allocator) anyerror![]const []const u8 {
        return self.vtable.installedExplicit(self.ctx, arena);
    }

    pub fn install(self: Backend, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        return self.vtable.install(self.ctx, arena, rows);
    }

    pub fn declare(self: Backend, arena: std.mem.Allocator, id: []const u8) anyerror!Declaration {
        return self.vtable.declare(self.ctx, arena, id);
    }
};
