//! The contract every package manager is reached through.
//!
//! The core knows only these operations. Everything a manager needs
//! beyond them -- which keys its rows accept, which executable proves it is
//! installed, how a qualified name is spelled -- is the adapter's, so adding
//! a manager never edits the core and a manager's own churn never leaves its
//! adapter.

const std = @import("std");

const exec = @import("exec.zig");
const manifest_mod = @import("manifest.zig");

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;

/// The one character class an id or a name may use: no whitespace, no control
/// byte (0x7f included), valid UTF-8. UTF-8 because both are re-emitted into
/// documents that must parse -- a TOML manifest row, a `--json` report -- and
/// one byte no encoder can represent turns an odd package into a file no
/// reader will take.
fn plainText(s: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |c| {
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    }
    return true;
}

/// Whether an id has the shape of one id. Empty, whitespace inside, or over
/// 256 bytes says the backend padded its output or lost its line separator
/// (dnf5 concatenates every name when its format string lacks a newline);
/// this catches that for a large set, and the fixture tests catch the rest.
/// The class is `nameShapeOk`'s, because `declare` may answer `name = <id>`:
/// an id outside it would become a manifest row the next run refuses to load.
pub fn idShapeOk(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    return plainText(id);
}

/// Whether a `name` is one a manifest can carry and a manager can be handed.
/// The single authority on that: the manifest loader refuses a row outside
/// this class, so everything that invents a name -- a plugin's `declare`, an
/// adapter answering with its id -- is held to the same rule before the row is
/// written, and nothing can record a row every later run then refuses.
pub fn nameShapeOk(name: []const u8) bool {
    if (name.len == 0) return false;
    return plainText(name);
}

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
    /// Registered but not runnable on this machine (a plugin of a kind this
    /// OS cannot execute): its rows are neither desired nor judged here, and
    /// a bootstrap row for it is left for the machine that can run it.
    inert: bool = false,
    /// What this adapter structurally cannot see, in one line, or null when
    /// it can answer everything asked of it. A manager with no
    /// explicitly-installed query cannot report a package the user installed
    /// by hand, and reporting nothing is indistinguishable from reporting
    /// that there is nothing -- so the gap is stated rather than left to be
    /// discovered.
    limitation: ?[]const u8 = null,

    /// What probing a manager found. `broken` is a manager that is there but
    /// cannot answer its own version query: reading that as absent would make
    /// every row naming it inert without a word.
    pub const Availability = union(enum) {
        present,
        absent,
        broken: Broken,

        pub const Broken = struct {
            /// The exit code of the probe.
            code: u8,
            /// The probe's argv[0], as it was invoked.
            /// What was asked, for a message: `brew --version`, or a
            /// plugin's `macports available`.
            probe: []const u8,
        };
    };

    pub const VTable = struct {
        /// Whether this manager is usable on this machine.
        available: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Availability,
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
        /// Install the manager itself from an installer mox has already
        /// fetched and digest-verified at `installer_path`. Returns a directory
        /// to put on PATH so this same run can use what it installed, or null.
        /// Absent for a manager that ships with the OS, which is five of the
        /// seven: there is nothing to install.
        bootstrap: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 = null,
        /// What this backend structurally cannot see, asked once of a usable
        /// backend. Absent when the `limitation` field states it, or when there is
        /// nothing to state.
        limitation: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8 = null,
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

    pub fn available(self: Backend, arena: std.mem.Allocator) anyerror!Availability {
        return self.vtable.available(self.ctx, arena);
    }

    /// The availability a probe answers: not there at
    /// all is absent, exit 0 is present, any other exit is broken. A spawn
    /// failure other than an absent executable is an error, never absent.
    pub fn probeAvailability(probe: []const u8, result: anyerror!exec.Result) anyerror!Availability {
        const res = result catch |e| switch (e) {
            error.FileNotFound => return .absent,
            else => return e,
        };
        try exec.checkTimedOut(res);
        if (res.ok) return .present;
        return .{ .broken = .{ .code = res.code, .probe = probe } };
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

    /// The declared limitation, or the answer to the `limitation` verb.
    pub fn limitationOf(self: Backend, arena: std.mem.Allocator) anyerror!?[]const u8 {
        if (self.limitation) |l| return l;
        const f = self.vtable.limitation orelse return null;
        return f(self.ctx, arena);
    }

    pub fn canBootstrap(self: Backend) bool {
        return self.vtable.bootstrap != null;
    }

    pub fn bootstrap(self: Backend, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const f = self.vtable.bootstrap orelse return error.NoBootstrapForBackend;
        return f(self.ctx, arena, installer_path);
    }
};

const testing = std.testing;

test "idShapeOk: an id that could not be written back as a name is refused" {
    try testing.expect(idShapeOk("ripgrep"));
    try testing.expect(idShapeOk("cask:ghostty"));
    try testing.expect(idShapeOk("d12frosted/emacs-plus/emacs-plus@30"));
    // A name is spelled in the user's language; only the bytes below 0x80
    // decide the shape.
    try testing.expect(idShapeOk("日本語"));

    try testing.expect(!idShapeOk(""));
    try testing.expect(!idShapeOk("ripgrep bat"));
    try testing.expect(!idShapeOk("ripgrep\tbat"));
    try testing.expect(!idShapeOk("rip\ngrep"));
    try testing.expect(!idShapeOk("x" ** 257));
    // The bytes an id shares with a name: the whole whitespace class, every
    // control byte, and anything that is not UTF-8.
    try testing.expect(!idShapeOk("rip\x0bgrep"));
    try testing.expect(!idShapeOk("rip\x0cgrep"));
    try testing.expect(!idShapeOk("rip\x1bgrep"));
    try testing.expect(!idShapeOk("rip\x7fgrep"));
    try testing.expect(!idShapeOk("rip\x00grep"));
    try testing.expect(!idShapeOk("rip\xffgrep"));
    try testing.expect(!idShapeOk("\xed\xa0\x80"));
}

test "nameShapeOk: the class the manifest loader enforces, applied before a row is written" {
    try testing.expect(nameShapeOk("ripgrep"));
    try testing.expect(nameShapeOk("emacs-plus@30"));

    try testing.expect(!nameShapeOk(""));
    try testing.expect(!nameShapeOk(" "));
    try testing.expect(!nameShapeOk("gnu make"));
    try testing.expect(!nameShapeOk("gnu\x0bmake"));
    try testing.expect(!nameShapeOk("gnu\x0cmake"));
    try testing.expect(!nameShapeOk("gnu\x7fmake"));
    try testing.expect(!nameShapeOk("gnu\x01make"));
    try testing.expect(!nameShapeOk("gnu\xffmake"));

    // No id may become a name the manifest would then refuse.
    const outside = [_][]const u8{ "gnu make", "gnu\x0bmake", "gnu\x7fmake", "gnu\xffmake", "" };
    for (outside) |s| try testing.expect(!idShapeOk(s));
}
