//! One pass from manifest to per-backend drift, shared by every command that
//! needs it: `status` prints it, `apply` installs what it reports missing,
//! `commit` reconciles what it reports untracked. Building it once keeps
//! those three from drifting apart in what they consider desired.
//!
//! A repo with no `data/packages/` is not using the subsystem, and `gather`
//! says so rather than reporting every installed package as untracked.

const std = @import("std");

const axis = @import("../dsl/axis.zig");
const resolver_mod = @import("../dsl/resolver.zig");
const backend_mod = @import("backend.zig");
const desired_mod = @import("desired.zig");
const drift_mod = @import("drift.zig");
const manifest_mod = @import("manifest.zig");
const validate_mod = @import("validate.zig");

const Io = std.Io;

pub const Backend = backend_mod.Backend;
pub const Registry = backend_mod.Registry;
pub const Resolver = resolver_mod.Resolver;
pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Drift = drift_mod.Drift;

/// One active backend's drift.
pub const BackendDrift = struct {
    backend: []const u8,
    drift: Drift,
    /// Carried from the adapter so a caller can state what this backend
    /// cannot see without knowing which manager it is.
    limitation: ?[]const u8 = null,
};

/// A manager that is there but cannot answer its own version query. Treated
/// as absent for the rows, and reported as drift: a machine whose brew is
/// broken is not a clean machine.
pub const Broken = struct {
    backend: []const u8,
    /// What was asked of it, for the message.
    probe: []const u8,
    code: u8,
};

pub const Report = struct {
    in_use: bool = false,
    backends: []const BackendDrift = &.{},
    /// What the report has to say beyond any one backend's rows: a probe
    /// that failed for a manager no row names, or no usable manager at all.
    notes: []const []const u8 = &.{},
    broken: []const Broken = &.{},

    /// Nothing to do here: no drift under any backend, and every manager
    /// that should have answered did.
    pub fn clean(self: Report) bool {
        if (self.broken.len > 0) return false;
        for (self.backends) |b| {
            if (!b.drift.clean()) return false;
        }
        return true;
    }

    pub fn missingCount(self: Report) usize {
        var n: usize = 0;
        for (self.backends) |b| n += b.drift.missing.len;
        return n;
    }

    pub fn untrackedCount(self: Report) usize {
        var n: usize = 0;
        for (self.backends) |b| n += b.drift.untracked.len;
        return n;
    }
};

/// Load the manifest, check it, and compute drift for every backend usable
/// here. A backend the machine cannot use contributes nothing: its rows are
/// inert and it is never queried.
pub fn gather(
    arena: std.mem.Allocator,
    io: Io,
    registry: Registry,
    repo_dir: []const u8,
    private_dir: []const u8,
    r: *const Resolver,
    diag: ?*Diag,
) !Report {
    const m = try manifest_mod.load(arena, io, repo_dir, private_dir, diag);
    return fromManifest(arena, m, registry, r, &.{}, diag);
}

/// `gather` for a manifest already loaded, so a caller that reads it for its
/// own reasons does not read it twice. `assume_available` names backends to
/// treat as usable with nothing installed, without asking them: a dry run
/// must be able to plan the rows of a manager it is not going to bootstrap
/// for real.
///
/// A backend that is absent but has a `[[bootstrap]]` row whose gate holds
/// is assumed the same way without being named: `apply` would bootstrap it
/// and install every row, so a report that called the machine clean would
/// contradict what apply is about to do. A manager that is there but cannot
/// answer its probe is reported broken: its rows cannot be judged, and a
/// machine in that state is not a clean one.
pub fn fromManifest(
    arena: std.mem.Allocator,
    m: manifest_mod.Manifest,
    registry: Registry,
    r: *const Resolver,
    assume_available: []const []const u8,
    diag: ?*Diag,
) !Report {
    if (!m.inUse()) return .{};

    try validate_mod.all(arena, m, registry, diag);

    var notes: std.ArrayList([]const u8) = .empty;
    var broken: std.ArrayList(Broken) = .empty;
    var active: std.ArrayList([]const u8) = .empty;
    var usable: std.ArrayList(Backend) = .empty;
    var assumed: std.ArrayList(Backend) = .empty;
    for (registry.backends) |b| {
        if (contains(assume_available, b.name)) {
            try active.append(arena, b.name);
            try assumed.append(arena, b);
            continue;
        }
        const avail = b.available(arena) catch |e| {
            // A backend no row names has nothing to judge, so its probe
            // failing must not take every other backend's report with it.
            if (!named(m, b.name)) {
                try notes.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{s}: available failed: {s}; treated as absent",
                    .{ b.name, @errorName(e) },
                ));
                continue;
            }
            if (diag) |d| d.set("{s}: available failed: {s}", .{ b.name, @errorName(e) });
            return e;
        };
        switch (avail) {
            .present => {
                try active.append(arena, b.name);
                try usable.append(arena, b);
                continue;
            },
            .absent => {},
            // Broken is drift only for a manager the manifest asks about:
            // one no row names has nothing here to go wrong, and a machine
            // whose unrelated manager is damaged is not this repo's drift.
            // A manager that is there but cannot answer is a broken install
            // to repair, never one to install over: it is not absent, so no
            // bootstrap row applies to it and none of its rows can be judged.
            .broken => |why| {
                if (actedOn(m, b.name)) {
                    try broken.append(arena, .{ .backend = b.name, .probe = why.probe, .code = why.code });
                } else {
                    // A blacklist row names a backend without asking it for
                    // anything, so "no row names it" would be false there.
                    try notes.append(arena, try std.fmt.allocPrint(
                        arena,
                        "{s}: {s} exited {d}; no row asks it to install anything, so nothing here needs it",
                        .{ b.name, why.probe, why.code },
                    ));
                }
                continue;
            },
        }
        if (b.inert) continue;
        if (try willBootstrap(arena, m, b.name, r)) {
            try active.append(arena, b.name);
            try assumed.append(arena, b);
        }
    }
    if (active.items.len == 0) try notes.append(arena, "no package manager is usable on this machine");

    const rows = try desired_mod.select(arena, m, r, registry, active.items, diag);

    var out: std.ArrayList(BackendDrift) = .empty;
    for (assumed.items) |b| {
        try out.append(arena, .{
            .backend = b.name,
            .drift = drift_mod.compute(arena, b, rows, &.{}, m) catch |e| {
                if (diag) |d| d.set("{s}: id failed: {s}", .{ b.name, @errorName(e) });
                return e;
            },
            .limitation = if (contains(assume_available, b.name)) null else "absent; apply will bootstrap it",
        });
    }
    for (usable.items) |b| {
        const installed = b.installedExplicit(arena) catch |e| {
            if (diag) |d| d.set("{s}: list failed: {s}", .{ b.name, @errorName(e) });
            return e;
        };
        for (installed) |id| {
            if (backend_mod.idShapeOk(id)) continue;
            if (diag) |d| d.set(
                "{s}: reported an id that is not one id ({d} bytes, or contains whitespace); its list output lost its shape",
                .{ b.name, id.len },
            );
            return error.BackendBadOutput;
        }
        const limitation = b.limitationOf(arena) catch |e| {
            if (diag) |d| d.set("{s}: limitation failed: {s}", .{ b.name, @errorName(e) });
            return e;
        };
        try out.append(arena, .{
            .backend = b.name,
            .drift = drift_mod.compute(arena, b, rows, installed, m) catch |e| {
                if (diag) |d| d.set("{s}: id failed: {s}", .{ b.name, @errorName(e) });
                return e;
            },
            .limitation = limitation,
        });
    }

    return .{
        .in_use = true,
        .backends = try out.toOwnedSlice(arena),
        .notes = try notes.toOwnedSlice(arena),
        .broken = try broken.toOwnedSlice(arena),
    };
}

/// Whether any package, blacklist, or bootstrap row names `backend`.
fn named(m: manifest_mod.Manifest, backend: []const u8) bool {
    for (m.packages) |row| if (std.mem.eql(u8, row.backend, backend)) return true;
    for (m.blacklist) |row| if (std.mem.eql(u8, row.backend, backend)) return true;
    for (m.bootstrap) |row| if (std.mem.eql(u8, row.backend, backend)) return true;
    return false;
}

/// Whether the manifest asks this backend to do anything. A blacklist row
/// asks for nothing to happen, so a manager named by one alone has nothing
/// to install and nothing to judge: its being broken is worth a note, not
/// drift the run can never clear.
fn actedOn(m: manifest_mod.Manifest, backend: []const u8) bool {
    for (m.packages) |row| if (std.mem.eql(u8, row.backend, backend)) return true;
    for (m.bootstrap) |row| if (std.mem.eql(u8, row.backend, backend)) return true;
    return false;
}

/// Whether `apply` would bootstrap `backend` here: a `[[bootstrap]]` row
/// names it and the row's gate holds. A gate that fails to parse is an
/// error, as it is for a package row: `manifest.load` refused a malformed
/// one, so what reaches here is an allocation failure.
fn willBootstrap(arena: std.mem.Allocator, m: manifest_mod.Manifest, backend: []const u8, r: *const Resolver) !bool {
    for (m.bootstrap) |b| {
        if (!std.mem.eql(u8, b.backend, backend)) continue;
        const src = b.when orelse return true;
        const expr = try axis.parseString(arena, src);
        if (axis.evaluate(expr, r)) return true;
    }
    return false;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");
const exec = @import("exec.zig");
const brew_mod = @import("brew.zig");
const plugin_mod = @import("plugin.zig");

fn rowOf(name: []const u8, backend: []const u8) Row {
    return .{
        .name = name,
        .backend = backend,
        .when = null,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

test "fromManifest: a repo not using the subsystem reports nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // No manifest files: every installed package would otherwise read as
    // untracked on a machine that never opted in.
    const m: manifest_mod.Manifest = .{ .files = 0 };
    const rep = try fromManifest(a, m, .{ .backends = &.{} }, &r, &.{}, null);
    try testing.expect(!rep.in_use);
    try testing.expect(rep.clean());
}

test "fromManifest: an unusable backend is never queried" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // test_backend's `available` is unreachable, so a query would error.
    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("bat", "dnf")},
        .files = 1,
    };
    try testing.expectError(error.Unreached, fromManifest(a, m, .{ .backends = &.{test_backend.make("dnf")} }, &r, &.{}, null));
}

test "fromManifest: drift comes back per backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "ripgrep\nhtop\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{ rowOf("ripgrep", "brew"), rowOf("fd", "brew") },
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expect(rep.in_use);
    try testing.expectEqual(@as(usize, 1), rep.backends.len);
    try testing.expectEqualStrings("brew", rep.backends[0].backend);
    // `fd` is declared but absent; `htop` is installed but declared nowhere.
    try testing.expectEqual(@as(usize, 1), rep.missingCount());
    try testing.expectEqualStrings("fd", rep.backends[0].drift.missing[0].row.name);
    try testing.expectEqual(@as(usize, 1), rep.untrackedCount());
    try testing.expectEqualStrings("htop", rep.backends[0].drift.untracked[0]);
    try testing.expect(!rep.clean());
}

test "fromManifest: a manifest matching the machine is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "ripgrep\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "ghostty\n" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const cask: Row = .{
        .name = "ghostty",
        .backend = "brew",
        .when = null,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
    const m: manifest_mod.Manifest = .{
        .packages = &.{ rowOf("ripgrep", "brew"), cask },
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expect(rep.clean());
}

test "fromManifest: an invalid manifest is refused before anything is queried" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brw")},
        .files = 1,
    };

    var d: Diag = .{};
    try testing.expectError(
        validate_mod.Error.UnknownBackend,
        fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, &d),
    );
}

fn bootstrapRowOf(backend: []const u8, when: ?[]const u8) manifest_mod.BootstrapRow {
    return .{
        .backend = backend,
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
        .when = when,
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

test "fromManifest: an absent backend apply would bootstrap is assumed, its rows missing, and said so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // brew is absent and never asked to list anything.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .fail = error.FileNotFound },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brew")},
        .bootstrap = &.{bootstrapRowOf("brew", "os=darwin")},
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 1), rep.backends.len);
    try testing.expectEqualStrings("brew", rep.backends[0].backend);
    try testing.expectEqualStrings("absent; apply will bootstrap it", rep.backends[0].limitation.?);
    try testing.expectEqual(@as(usize, 1), rep.missingCount());
    try testing.expectEqual(@as(usize, 0), rep.untrackedCount());
    try testing.expect(!rep.clean());
    try testing.expectEqual(@as(usize, 0), rep.notes.len);
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "fromManifest: a bootstrap row whose gate excludes this machine assumes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "linux");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .fail = error.FileNotFound },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brew")},
        .bootstrap = &.{bootstrapRowOf("brew", "os=darwin")},
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 0), rep.backends.len);
    try testing.expect(rep.clean());
    try testing.expectEqual(@as(usize, 1), rep.notes.len);
    try testing.expectEqualStrings("no package manager is usable on this machine", rep.notes[0]);
}

test "fromManifest: an inert backend is not assumed for its bootstrap row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var p: plugin_mod.Plugin = .{
        .io = std.testing.io,
        .name = "scoopish",
        .argv0 = &.{},
        .runner = fake.runner(),
        .alloc = a,
        .not_runnable = "a windows-only kind; not runnable here",
    };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("7zip", "scoopish")},
        .bootstrap = &.{bootstrapRowOf("scoopish", null)},
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{p.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 0), rep.backends.len);
    try testing.expect(rep.clean());
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "fromManifest: a broken backend is not bootstrapped over, whatever the manifest declares" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // brew answers its probe with an error and the manifest declares an
    // installer for it. Installing over a broken manager would be judged
    // against a manager that cannot answer, so neither happens.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .code = 1 },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };
    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brew")},
        .bootstrap = &.{bootstrapRowOf("brew", null)},
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 1), rep.broken.len);
    // No backend drift at all: its rows were not judged.
    try testing.expectEqual(@as(usize, 0), rep.backends.len);
    try testing.expect(!rep.clean());
}

test "fromManifest: a broken backend is treated as absent and listed as broken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // brew's own version query fails: it is never asked to list.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .code = 1 },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brew")},
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 0), rep.backends.len);
    // Broken is drift of its own: nothing to install, but nothing clean.
    try testing.expect(!rep.clean());
    try testing.expectEqual(@as(usize, 1), rep.broken.len);
    try testing.expectEqualStrings("brew", rep.broken[0].backend);
    try testing.expectEqualStrings("brew --version", rep.broken[0].probe);
    try testing.expectEqual(@as(u8, 1), rep.broken[0].code);
    try testing.expectEqual(@as(usize, 1), rep.notes.len);
    try testing.expectEqualStrings("no package manager is usable on this machine", rep.notes[0]);
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "fromManifest: a broken manager only a blacklist row names is a note saying what is true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .code = 1 },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    // A blacklist row names brew but asks it for nothing, so its being
    // broken is a note rather than drift no run could ever clear.
    const bl: manifest_mod.BlacklistRow = .{
        .name = "usage",
        .backend = "brew",
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
    const m: manifest_mod.Manifest = .{ .blacklist = &.{bl}, .files = 1 };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 0), rep.broken.len);
    try testing.expectEqual(@as(usize, 0), rep.backends.len);
    try testing.expect(rep.clean());
    try testing.expectEqualStrings(
        "brew: brew --version exited 1; no row asks it to install anything, so nothing here needs it",
        rep.notes[0],
    );
}

test "fromManifest: a probe error on a backend no row names is a note, and the report still comes back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "ripgrep\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    // test_backend's `available` errors; nothing names dnf.
    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brew")},
        .files = 1,
    };
    const rep = try fromManifest(a, m, .{ .backends = &.{ b.backend(), test_backend.make("dnf") } }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 1), rep.backends.len);
    try testing.expectEqualStrings("brew", rep.backends[0].backend);
    try testing.expect(rep.clean());
    try testing.expectEqual(@as(usize, 1), rep.notes.len);
    try testing.expectEqualStrings("dnf: available failed: Unreached; treated as absent", rep.notes[0]);
}

test "fromManifest: a probe error on a backend a blacklist or bootstrap row names still aborts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const bl: manifest_mod.BlacklistRow = .{
        .name = "usage",
        .backend = "dnf",
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
    const by_blacklist: manifest_mod.Manifest = .{ .blacklist = &.{bl}, .files = 1 };
    var d: Diag = .{};
    try testing.expectError(error.Unreached, fromManifest(a, by_blacklist, .{ .backends = &.{test_backend.make("dnf")} }, &r, &.{}, &d));
    try testing.expectEqualStrings("dnf: available failed: Unreached", d.capture().?);

    const by_bootstrap: manifest_mod.Manifest = .{ .bootstrap = &.{bootstrapRowOf("dnf", null)}, .files = 1 };
    try testing.expectError(error.Unreached, fromManifest(a, by_bootstrap, .{ .backends = &.{test_backend.makeBootstrappable("dnf")} }, &r, &.{}, null));
}

test "fromManifest: a usable backend leaves no note about usability" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{ .packages = &.{}, .files = 1 };
    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &.{}, null);
    try testing.expectEqual(@as(usize, 0), rep.notes.len);
    // Whatever limitation rides here is the adapter's own; being usable adds
    // nothing, and never "absent; apply will bootstrap it".
    try testing.expectEqual(b.backend().limitation, rep.backends[0].limitation);
}
