//! Manifest checks that hold on every machine, run once after loading.
//!
//! A row naming an unregistered backend, a key its adapter does not accept,
//! or a package both declared and blacklisted is wrong wherever it is read --
//! not wrong only where that manager happens to be installed. So these run
//! against the whole manifest, ungated and regardless of which backends this
//! machine can use, and none of them is a skip.

const std = @import("std");

const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

pub const Registry = backend_mod.Registry;
pub const Manifest = manifest_mod.Manifest;
pub const Diag = manifest_mod.Diag;

pub const Error = error{
    UnknownBackend,
    BlacklistedPackageDeclared,
    BootstrapUnsupported,
    DuplicateBootstrapRow,
    DuplicatePackageRow,
};

/// Check every row against the registry and its adapter. `diag` (when
/// non-null) names the file and row behind any failure. A file's label
/// carries its layer, so every message below tells two files of one basename
/// apart by naming one of them.
pub fn all(
    arena: std.mem.Allocator,
    m: Manifest,
    registry: Registry,
    diag: ?*Diag,
) !void {
    // Before any row: a row inheriting a mistyped file default would
    // otherwise be blamed for a key it does not carry, and a file holding
    // nothing but `backend = "brw"` -- the file the docs have you create
    // first -- would pass with no row to blame at all.
    for (m.sources) |src| {
        const name = src.default_backend orelse continue;
        if (registry.find(name) != null) continue;
        if (diag) |d| d.set(
            "{s}: file-level \"backend\": no backend named \"{s}\"",
            .{ src.label, name },
        );
        return Error.UnknownBackend;
    }

    for (m.packages) |row| {
        const b = registry.find(row.backend) orelse {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": no backend named \"{s}\"",
                .{ row.label, row.name, row.backend },
            );
            return Error.UnknownBackend;
        };
        try b.validate(row, diag);
    }

    for (m.blacklist) |bl| {
        const b = registry.find(bl.backend) orelse {
            if (diag) |d| d.set(
                "{s}: blacklist row {d} \"{s}\": no backend named \"{s}\"",
                .{ bl.label, bl.index, bl.name, bl.backend },
            );
            return Error.UnknownBackend;
        };
        try blacklistValidate(b, bl, diag);
    }

    // A bootstrap row names its backend the same way, and a typo there would
    // otherwise surface only on the one apply that needs the installer.
    var installers = std.StringHashMap(manifest_mod.BootstrapRow).init(arena);
    defer installers.deinit();
    for (m.bootstrap) |b| {
        if (installers.get(b.backend)) |first| {
            if (diag) |d| d.set(
                "{s}: bootstrap row {d} declares a second bootstrap row for backend \"{s}\"; one per backend (the first is {s}: bootstrap row {d})",
                .{ b.label, b.index, b.backend, first.label, first.index },
            );
            return Error.DuplicateBootstrapRow;
        }
        try installers.put(b.backend, b);
        const backend = registry.find(b.backend) orelse {
            if (diag) |d| d.set(
                "{s}: bootstrap row {d}: no backend named \"{s}\"",
                .{ b.label, b.index, b.backend },
            );
            return Error.UnknownBackend;
        };
        // A manager that ships with its OS has no installer to run; a row
        // declaring one is wrong on every machine. A plugin this machine
        // cannot run is judged where it runs.
        if (!backend.inert and !backend.canBootstrap()) {
            if (diag) |d| d.set(
                "{s}: bootstrap row {d}: backend \"{s}\" cannot be bootstrapped; it ships with the OS",
                .{ b.label, b.index, b.backend },
            );
            return Error.BootstrapUnsupported;
        }
    }

    try contradictions(arena, m, registry, diag);
    try duplicates(arena, m, registry, diag);
}

/// An adapter is handed a blacklist row shaped as a package row, and titles
/// its refusal `<label>: row "<name>": <why>` -- which names the
/// `[[packages]]` row of that name, a different row that may be perfectly
/// good. Re-title it so the row it refused is the row it names.
fn blacklistValidate(b: backend_mod.Backend, bl: manifest_mod.BlacklistRow, diag: ?*Diag) !void {
    var scratch: Diag = .{};
    b.validate(bl.asRow(), &scratch) catch |e| {
        if (diag) |d| {
            if (adapterReason(scratch.capture(), bl)) |why| {
                d.set("{s}: blacklist row {d} \"{s}\": {s}", .{ bl.label, bl.index, bl.name, why });
            } else {
                d.set("{s}: blacklist row {d} \"{s}\": {s}", .{ bl.label, bl.index, bl.name, exec.errorText(e) });
            }
        }
        return e;
    };
}

/// The adapter's own words with the row title it prefixed them with removed.
/// Null when it said nothing; a message shaped otherwise is kept whole, so a
/// re-titling never eats what an adapter has to say.
fn adapterReason(msg: ?[]const u8, bl: manifest_mod.BlacklistRow) ?[]const u8 {
    var rest = msg orelse return null;
    for ([_][]const u8{ bl.label, ": row \"", bl.name, "\": " }) |part| {
        if (!std.mem.startsWith(u8, rest, part)) return msg;
        rest = rest[part.len..];
    }
    return rest;
}

/// Two `[[packages]]` rows naming one package (by backend id) under the
/// same gate. Checked ungated: `desired.select` sees only the rows active
/// here, so a pair gated to another OS would pass every machine but the one
/// it breaks. Gates are compared as text -- two spellings of one condition
/// are left to `desired.select`, which still refuses them where both hold.
fn duplicates(
    arena: std.mem.Allocator,
    m: Manifest,
    registry: Registry,
    diag: ?*Diag,
) !void {
    var seen = std.StringHashMap(manifest_mod.Row).init(arena);
    defer seen.deinit();
    for (m.packages) |row| {
        const b = registry.find(row.backend) orelse continue;
        if (b.inert) continue;
        const id = b.idOf(arena, row) catch |e| {
            if (diag) |d| d.set("{s}: row \"{s}\": id failed: {s}", .{ row.label, row.name, exec.errorText(e) });
            return e;
        };
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ row.backend, id, row.when orelse "" });
        if (seen.get(key)) |first| {
            if (diag) |d| d.set(
                "{s}: row {d} and {s}: row {d} both declare \"{s}\" for backend \"{s}\" with the same gate",
                .{ first.label, first.index, row.label, row.index, row.name, row.backend },
            );
            return Error.DuplicatePackageRow;
        }
        try seen.put(key, row);
    }
}

/// A package both declared and blacklisted. Compared by backend id, so a
/// blacklisted cask never collides with the formula of the same name, and
/// checked ungated: a blacklist holds regardless of which machine asks, so
/// the contradiction must not surface only where the gate happens to pass.
fn contradictions(
    arena: std.mem.Allocator,
    m: Manifest,
    registry: Registry,
    diag: ?*Diag,
) !void {
    for (m.blacklist) |bl| {
        const b = registry.find(bl.backend) orelse continue;
        // Only the machine that can run the backend can name its packages;
        // elsewhere the rows are inert, and comparing them by bare name here
        // would refuse a shared manifest on exactly the OS that cannot judge it.
        if (b.inert) continue;
        const blocked = b.idOf(arena, bl.asRow()) catch |e| {
            if (diag) |d| d.set("{s}: blacklist row {d} \"{s}\": id failed: {s}", .{ bl.label, bl.index, bl.name, exec.errorText(e) });
            return e;
        };
        for (m.packages) |row| {
            if (!std.mem.eql(u8, row.backend, bl.backend)) continue;
            const id = b.idOf(arena, row) catch |e| {
                if (diag) |d| d.set("{s}: row \"{s}\": id failed: {s}", .{ row.label, row.name, exec.errorText(e) });
                return e;
            };
            if (!std.mem.eql(u8, id, blocked)) continue;
            if (diag) |d| d.set(
                "{s}: row {d} declares \"{s}\" for backend \"{s}\", which {s}: blacklist row {d} blacklists",
                .{ row.label, row.index, row.name, row.backend, bl.label, bl.index },
            );
            return Error.BlacklistedPackageDeclared;
        }
    }
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");
const exec = @import("exec.zig");
const brew_mod = @import("brew.zig");

fn sourceOf(label: []const u8, default_backend: ?[]const u8) manifest_mod.Source {
    return .{ .path = "/tmp/x.toml", .label = label, .default_backend = default_backend, .private = false };
}

fn rowOf(name: []const u8, backend: []const u8, when: ?[]const u8) manifest_mod.Row {
    return rowAt(name, backend, when, "data/packages/a.toml", 0);
}

fn rowAt(name: []const u8, backend: []const u8, when: ?[]const u8, label: []const u8, index: usize) manifest_mod.Row {
    return .{
        .name = name,
        .backend = backend,
        .when = when,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = label,
        .index = index,
    };
}

fn bootstrapAt(backend: []const u8, label: []const u8, index: usize) manifest_mod.BootstrapRow {
    return .{
        .backend = backend,
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
        .when = null,
        .origin = "/tmp/x.toml",
        .label = label,
        .index = index,
    };
}

fn caskRow(name: []const u8) manifest_mod.Row {
    return .{
        .name = name,
        .backend = "brew",
        .when = null,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

fn blacklistOf(name: []const u8, backend: []const u8, fields: []const manifest_mod.Pair) manifest_mod.BlacklistRow {
    return .{
        .name = name,
        .backend = backend,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/local.toml",
        .index = 0,
    };
}

fn registryOf(backends: []const backend_mod.Backend) Registry {
    return .{ .backends = backends };
}

test "all: a row naming no registered backend is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .packages = &.{rowOf("ripgrep", "brw", null)} };

    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, m, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: row \"ripgrep\": no backend named \"brw\"",
        d.capture().?,
    );
}

test "all: a backend this machine cannot use is still a known backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A dnf row on a mac is registered and valid; only its availability
    // differs, and that is not this pass's business.
    const brew = test_backend.make("brew");
    const dnf = test_backend.make("dnf");
    const m: Manifest = .{ .packages = &.{rowOf("bat", "dnf", null)} };

    try all(a, m, registryOf(&.{ brew, dnf }), null);
}

test "all: a file-level backend naming no registered backend is refused, naming the file's key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const want = "data/packages/a.toml: file-level \"backend\": no backend named \"brw\"";

    // The file the docs have you write first: a default and not one row yet.
    const bare: Manifest = .{ .sources = &.{sourceOf("data/packages/a.toml", "brw")} };
    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, bare, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(want, d.capture().?);

    // A row inheriting that default is not the thing that is wrong.
    const inherited: Manifest = .{
        .packages = &.{rowOf("ripgrep", "brw", null)},
        .sources = &.{sourceOf("data/packages/a.toml", "brw")},
    };
    var d2: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, inherited, registryOf(&.{brew}), &d2));
    try testing.expectEqualStrings(want, d2.capture().?);
}

test "all: a file declaring a registered default is fine, and a file with no default is not checked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/a.toml", "brew"),
        sourceOf("data/packages/b.toml", null),
    } };
    try all(a, m, registryOf(&.{brew}), null);
}

test "all: an adapter refusing a blacklist row names that row, not the packages row of the same name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var brew: brew_mod.Brew = .{ .runner = fake.runner() };

    // The `[[packages]]` row of this name is good; the blacklist row carries
    // a key brew does not take.
    const bl: manifest_mod.BlacklistRow = .{
        .name = "docker",
        .backend = "brew",
        .fields = &.{.{ .key = "flavor", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/local.toml (private layer)",
        .index = 2,
    };
    const m: Manifest = .{ .packages = &.{rowOf("docker", "brew", null)}, .blacklist = &.{bl} };

    var d: Diag = .{};
    try testing.expectError(error.UnknownBrewKey, all(a, m, registryOf(&.{brew.backend()}), &d));
    const msg = d.capture().?;
    try testing.expect(std.mem.startsWith(u8, msg, "data/packages/local.toml (private layer): blacklist row 2 \"docker\": "));
    try testing.expect(std.mem.indexOf(u8, msg, "flavor") != null);
    // The clean packages row is never the one named.
    try testing.expect(std.mem.indexOf(u8, msg, ": row \"docker\"") == null);
}

test "all: a bootstrap row naming no registered backend is refused, naming file and row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.makeBootstrappable("brew");
    const m: Manifest = .{ .bootstrap = &.{bootstrapAt("brw", "data/packages/darwin.toml", 1)} };

    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, m, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(
        "data/packages/darwin.toml: bootstrap row 1: no backend named \"brw\"",
        d.capture().?,
    );
}

test "all: a blacklist row naming no registered backend is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .blacklist = &.{blacklistOf("usage", "brw", &.{})} };

    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, m, registryOf(&.{brew}), &d));
}

test "all: a package both declared and blacklisted is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("usage", "brew", null)},
        .blacklist = &.{blacklistOf("usage", "brew", &.{})},
    };

    var d: Diag = .{};
    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), &d));
    // Both rows by file and index: two rows of one name are told apart by
    // nothing else.
    try testing.expectEqualStrings(
        "data/packages/a.toml: row 0 declares \"usage\" for backend \"brew\", which data/packages/local.toml: blacklist row 0 blacklists",
        d.capture().?,
    );
}

test "all: the contradiction surfaces even where the gate excludes the row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Gated to work machines, blacklisted outright: wrong everywhere, so it
    // must not wait for a work machine to say so.
    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("usage", "brew", "profile=work")},
        .blacklist = &.{blacklistOf("usage", "brew", &.{})},
    };

    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), null));
}

test "all: a blacklisted cask does not contradict the formula of the same name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("docker", "brew", null)},
        .blacklist = &.{blacklistOf("docker", "brew", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})},
    };

    try all(a, m, registryOf(&.{brew}), null);
}

test "all: a blacklisted cask does contradict the declared cask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{caskRow("docker")},
        .blacklist = &.{blacklistOf("docker", "brew", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})},
    };

    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), null));
}

test "all: a second bootstrap row for one backend is refused, naming both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.makeBootstrappable("brew");
    const m: Manifest = .{ .bootstrap = &.{
        bootstrapAt("brew", "data/packages/darwin.toml", 0),
        bootstrapAt("brew", "data/packages/local.toml", 0),
    } };

    var d: Diag = .{};
    try testing.expectError(Error.DuplicateBootstrapRow, all(a, m, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(
        "data/packages/local.toml: bootstrap row 0 declares a second bootstrap row for backend \"brew\"; one per backend (the first is data/packages/darwin.toml: bootstrap row 0)",
        d.capture().?,
    );
}

test "all: one bootstrap row per backend is fine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.makeBootstrappable("brew");
    const scoop = test_backend.makeBootstrappable("scoop");
    const m: Manifest = .{ .bootstrap = &.{
        bootstrapAt("brew", "data/packages/darwin.toml", 0),
        bootstrapAt("scoop", "data/packages/windows.toml", 0),
    } };
    try all(a, m, registryOf(&.{ brew, scoop }), null);
}

test "all: two identical rows under a gate this machine fails are still a duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both gated to linux: on a mac `desired.select` never sees either.
    const brew = test_backend.make("brew");
    const m: Manifest = .{ .packages = &.{
        rowAt("ripgrep", "brew", "os=linux", "data/packages/a.toml", 1),
        rowAt("ripgrep", "brew", "os=linux", "data/packages/local.toml", 0),
    } };

    var d: Diag = .{};
    try testing.expectError(Error.DuplicatePackageRow, all(a, m, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: row 1 and data/packages/local.toml: row 0 both declare \"ripgrep\" for backend \"brew\" with the same gate",
        d.capture().?,
    );
}

test "all: the same package under different gates, or with no gate beside a gate, is not a duplicate here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .packages = &.{
        rowAt("ripgrep", "brew", "profile=work", "data/packages/a.toml", 0),
        rowAt("ripgrep", "brew", "not profile=work", "data/packages/a.toml", 1),
        rowAt("ripgrep", "brew", null, "data/packages/local.toml", 0),
    } };
    try all(a, m, registryOf(&.{brew}), null);
}

test "all: two ungated identical rows are a duplicate, and a cask is not the formula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const ok: Manifest = .{ .packages = &.{ rowOf("docker", "brew", null), caskRow("docker") } };
    try all(a, ok, registryOf(&.{brew}), null);

    const dup: Manifest = .{ .packages = &.{ rowOf("docker", "brew", null), rowOf("docker", "brew", null) } };
    try testing.expectError(Error.DuplicatePackageRow, all(a, dup, registryOf(&.{brew}), null));
}
