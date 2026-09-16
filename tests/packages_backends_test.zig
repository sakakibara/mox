//! Backend adapters against the REAL package managers.
//!
//! Kept out of `zig build test` -- which must pass on a machine with no
//! package manager installed, and must never touch the one it has -- and run
//! by `zig build test-backends`. The day a manager changes the output or
//! flags an adapter depends on, this goes red.
//!
//! Every check here is READ-ONLY: nothing installs, taps, trusts, or removes.
//! The two that decide whether the adapter asks brew the right question are
//! DIFFERENTIAL against an INDEPENDENT oracle -- brew's own install receipts
//! under the Cellar and the Caskroom, never a `brew list` -- because an
//! adapter running the wrong query agrees with itself. The rest compare
//! spelling and arity against `brew list` itself, which is the right oracle
//! for "is this string verbatim". A check with no data to work on skips
//! rather than passing on nothing, and under CI both an absent brew and an
//! empty comparison are failures: the runner is seeded so neither happens.

const std = @import("std");
const mox = @import("mox");

const packages = mox.packages;
const testing = std.testing;

fn brewPresent(arena: std.mem.Allocator, io: std.Io) bool {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    const got = b.backend().available(arena) catch return false;
    return got == .present;
}

/// Skip a check that has no brew to ask -- unless this is CI, where the job
/// exists to run it: a silent skip there is a green that covered nothing.
fn needBrew(arena: std.mem.Allocator, io: std.Io) !void {
    if (brewPresent(arena, io)) return;
    if (onCi()) {
        std.debug.print("CI: brew is not installed on this runner; the adapter gate cannot run\n", .{});
        return error.TestUnexpectedResult;
    }
    return error.SkipZigTest;
}

fn onCi() bool {
    if (@import("builtin").os.tag == .windows) return false;
    const v = std.c.getenv("CI") orelse return false;
    return v[0] != 0;
}

/// What brew itself recorded when each package was installed, read from the
/// Cellar's `INSTALL_RECEIPT.json` files and the Caskroom's directories --
/// not from any brew query. An adapter asking brew the wrong question can
/// agree with `brew list`; it cannot agree with the receipts.
const Inventory = struct {
    /// Formula names (unqualified) whose receipt says the user asked for them.
    requested: []const []const u8,
    /// Formula names present as a dependency nobody asked for.
    dependencies: []const []const u8,
    /// Cask tokens (unqualified).
    casks: []const []const u8,
};

/// Every production call in the subsystem runs under a deadline; so must
/// these, or a brew blocked on its lock hangs the gate until the job's own
/// timeout kills it with nothing to show.
const brew_timeout_s = 120;

fn runBrew(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const timeout: std.Io.Timeout = .{
        .duration = .{ .raw = std.Io.Duration.fromSeconds(brew_timeout_s), .clock = .awake },
    };
    return std.process.run(arena, io, .{ .argv = argv, .timeout = timeout }) catch |err| {
        if (err == error.Timeout) {
            const cmd = std.mem.join(arena, " ", argv) catch "brew";
            std.debug.print("'{s}' did not answer within {d}s; brew is wedged, most likely on a held lock\n", .{ cmd, brew_timeout_s });
        }
        return err;
    };
}

fn brewPath(arena: std.mem.Allocator, io: std.Io, which: []const u8) ![]const u8 {
    const res = try runBrew(arena, io, &.{ "brew", which });
    if (res.term != .exited or res.term.exited != 0) return error.CommandFailed;
    return std.mem.trim(u8, res.stdout, " \t\r\n");
}

fn inventory(arena: std.mem.Allocator, io: std.Io) !Inventory {
    var requested: std.ArrayList([]const u8) = .empty;
    var dependencies: std.ArrayList([]const u8) = .empty;

    const cellar = try brewPath(arena, io, "--cellar");
    var cellar_dir = try std.Io.Dir.cwd().openDir(io, cellar, .{ .iterate = true });
    defer cellar_dir.close(io);
    var names = cellar_dir.iterate();
    while (try names.next(io)) |name_entry| {
        if (name_entry.kind != .directory) continue;
        const name = try arena.dupe(u8, name_entry.name);
        var kegs = try cellar_dir.openDir(io, name, .{ .iterate = true });
        defer kegs.close(io);
        var versions = kegs.iterate();
        var on_request = false;
        var seen_keg = false;
        // Homebrew answers for the latest keg, so two kegs whose receipts
        // disagree must not make the oracle answer for the other one. The
        // receipt's mtime is when brew last wrote that keg's request flag.
        var newest: i96 = std.math.minInt(i96);
        while (try versions.next(io)) |keg| {
            if (keg.kind != .directory) continue;
            const receipt = try std.fs.path.join(arena, &.{ cellar, name, keg.name, "INSTALL_RECEIPT.json" });
            const text = std.Io.Dir.cwd().readFileAlloc(io, receipt, arena, .limited(4 << 20)) catch continue;
            const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch continue;
            const stat = std.Io.Dir.cwd().statFile(io, receipt, .{}) catch continue;
            if (seen_keg and stat.mtime.nanoseconds <= newest) continue;
            seen_keg = true;
            newest = stat.mtime.nanoseconds;
            on_request = if (parsed.value.object.get("installed_on_request")) |f| f == .bool and f.bool else false;
        }
        if (!seen_keg) continue;
        if (on_request) try requested.append(arena, name) else try dependencies.append(arena, name);
    }

    var casks: std.ArrayList([]const u8) = .empty;
    const caskroom = try brewPath(arena, io, "--caskroom");
    if (std.Io.Dir.cwd().openDir(io, caskroom, .{ .iterate = true })) |*dir| {
        var d = dir.*;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try casks.append(arena, try arena.dupe(u8, entry.name));
        }
    } else |_| {}

    return .{
        .requested = try requested.toOwnedSlice(arena),
        .dependencies = try dependencies.toOwnedSlice(arena),
        .casks = try casks.toOwnedSlice(arena),
    };
}

/// Whether `ids` holds `name` itself or a tap-qualified spelling of it: the
/// Cellar knows a formula by its bare name, brew reports a third-party tap's
/// formula by its full name.
fn holdsFormula(ids: []const []const u8, name: []const u8) bool {
    for (ids) |id| {
        if (std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        if (std.mem.eql(u8, id, name)) return true;
        if (std.mem.endsWith(u8, id, name) and id.len > name.len and id[id.len - name.len - 1] == '/') return true;
    }
    return false;
}

/// `name` itself and nothing else: a tap-qualified id sharing this leaf names
/// a different formula, so the suffix match above would report the wrong one.
fn holdsFormulaExactly(ids: []const []const u8, name: []const u8) bool {
    for (ids) |id| {
        if (std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        if (std.mem.eql(u8, id, name)) return true;
    }
    return false;
}

fn holdsCask(ids: []const []const u8, token: []const u8) bool {
    for (ids) |id| {
        if (!std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        const rest = id[packages.brew.cask_prefix.len..];
        if (std.mem.eql(u8, rest, token)) return true;
        if (std.mem.endsWith(u8, rest, token) and rest.len > token.len and rest[rest.len - token.len - 1] == '/') return true;
    }
    return false;
}

/// A check with no data to compare skips rather than passing on nothing --
/// but under CI it fails: the runner is seeded so that the data is there,
/// and a skip means the job proved nothing it exists to prove.
fn skipUnlessCi(why: []const u8) anyerror {
    if (onCi()) {
        std.debug.print("CI: {s}; the adapter gate cannot run on nothing\n", .{why});
        return error.TestUnexpectedResult;
    }
    return error.SkipZigTest;
}

fn brewIds(arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    return b.backend().installedExplicit(arena);
}

/// The raw tool's own answer, read without going through the adapter.
fn rawLines(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const []const u8 {
    const res = try runBrew(arena, io, argv);
    if (res.term != .exited or res.term.exited != 0) return error.CommandFailed;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

test "brew: available agrees with brew answering for itself" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };

    // Off CI both answers may be "absent" and agree; on CI the runner has
    // brew, so agreeing on absence would prove nothing about the path that
    // matters.
    if (onCi()) try needBrew(a, io);
    const available = (b.backend().available(a) catch .absent) == .present;
    const answered = blk: {
        const res = std.process.run(a, io, .{ .argv = &.{ "brew", "--version" } }) catch break :blk false;
        break :blk res.term == .exited and res.term.exited == 0;
    };
    try testing.expectEqual(answered, available);
}

test "brew: the receipts' requested formulae are ids, and their dependencies are not" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const inv = try inventory(a, io);
    if (inv.requested.len == 0) return skipUnlessCi("no formula is installed on request");
    const ids = try brewIds(a, io);

    for (inv.requested) |name| {
        if (!holdsFormula(ids, name)) {
            std.debug.print("'{s}' was installed on request but is not an adapter id\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    // The other direction is what catches a query that lists everything: a
    // formula pulled in as a dependency is not tracked and must not appear.
    for (inv.dependencies) |name| {
        if (holdsFormulaExactly(ids, name)) {
            std.debug.print("'{s}' is an unrequested dependency but appears as an adapter id\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: the spelling is brew's own, verbatim" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const ids = try brewIds(a, io);
    const raw = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    if (raw.len == 0) return skipUnlessCi("brew lists no requested formula");

    // Verbatim: a formula must arrive unprefixed and untranslated, because
    // ids are compared against manifest names by exact match.
    for (raw) |name| {
        if (!contains(ids, name)) {
            std.debug.print("formula '{s}' missing from adapter ids\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: every cask in the caskroom is an id under the cask prefix" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const inv = try inventory(a, io);
    if (inv.casks.len == 0) return skipUnlessCi("no cask is installed");
    const ids = try brewIds(a, io);

    // Drops the prefix and this fails, which is the point: a cask sharing a
    // formula's name would otherwise satisfy that formula's row.
    for (inv.casks) |token| {
        if (!holdsCask(ids, token)) {
            std.debug.print("cask '{s}' missing from adapter ids under the cask prefix\n", .{token});
            return error.TestUnexpectedResult;
        }
        if (holdsFormulaExactly(ids, token)) {
            std.debug.print("cask '{s}' also present as a formula id\n", .{token});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: there is no explicit-install query for casks, which is what the limitation says" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // brew declares `--cask` and `--installed-on-request` as conflicting, so
    // this argv is refused at option parsing and lists nothing. The adapter's
    // whole-Caskroom query, and the limitation that states its cost, are only
    // right for as long as that holds.
    const res = try runBrew(a, io, &.{ "env", "HOMEBREW_NO_AUTO_UPDATE=1", "brew", "list", "--cask", "--full-name", "--installed-on-request" });
    if (res.term == .exited and res.term.exited == 0) {
        std.debug.print("brew now accepts --cask with --installed-on-request; the cask query can be made explicit and the limitation dropped\n", .{});
        return error.TestUnexpectedResult;
    }

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    try testing.expectEqualStrings(packages.brew.cask_limitation, b.backend().limitation.?);
}

test "brew: the adapter reports exactly what brew reports, nothing extra" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    const ids = try brewIds(a, io);
    const formulae = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    const casks = try rawLines(a, io, &.{ "brew", "list", "--cask", "--full-name" });
    // 0 == 0 would satisfy the count without comparing anything.
    if (formulae.len + casks.len == 0) return skipUnlessCi("brew lists nothing installed on request");
    try testing.expectEqual(formulae.len + casks.len, ids.len);
}

test "brew: a tap-qualified formula is reported the way a row spells it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    const raw = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    var qualified: ?[]const u8 = null;
    for (raw) |name| {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            qualified = name;
            break;
        }
    }
    // The one case that skips even under CI: covering it means installing
    // from a third-party tap, which no CI runner should do. It skips rather
    // than passing on an empty search, so it never reads as coverage.
    const name = qualified orelse {
        std.debug.print("brew: no tapped formula installed here; the tap check has nothing to compare\n", .{});
        return error.SkipZigTest;
    };

    const ids = try brewIds(a, io);
    try testing.expect(contains(ids, name));
    // Three segments, so the tap is derivable from the name alone.
    var parts = std.mem.splitScalar(u8, name, '/');
    _ = parts.next();
    _ = parts.next();
    try testing.expect(parts.next() != null);
}

test "brew: a name after -- is a name, which is why the install argv carries one" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // Read-only: neither argv can install anything. `--help` prints help, and
    // no formula may be named `--help`, brew names beginning with `-` being
    // outside its own naming rules.
    //
    // The hazard first: brew's parser exits 0 on an option-shaped operand, so
    // a row named `--help` would be counted installed, reported MISSING by
    // the query that follows, and installed again on every apply. Then the
    // defence: after a `--`, the same operand is a formula name brew does not
    // have, and the install fails as it should.
    const bare = try runBrew(a, io, &.{ "brew", "install", "--help" });
    if (bare.term != .exited or bare.term.exited != 0) {
        std.debug.print("brew install --help no longer exits 0; the hazard the name rule and the -- answer may have changed\n", .{});
        return error.TestUnexpectedResult;
    }

    const guarded = try runBrew(a, io, &.{ "brew", "install", "--", "--help" });
    if (guarded.term == .exited and guarded.term.exited == 0) {
        std.debug.print("brew install -- --help exits 0; brew no longer stops its option scan at --, and the install argv must be reconsidered\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "brew: the query that resolves a name answers an alias with the formula it stands for" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // Read-only, and the premise of the alias refusal: `brew install ag`
    // installs `the_silver_searcher`, which is the name `brew list
    // --full-name --installed-on-request` reports, so an `ag` row would be
    // missing and that formula untracked on every run.
    const res = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "ag", "ripgrep" });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("brew info --json=v2 -- ag ripgrep did not answer; the alias refusal has no name to offer\n", .{});
        return error.TestUnexpectedResult;
    }
    // Both operands come back in one answer, so the batch can be asked at
    // once rather than a formula at a time.
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"full_name\": \"the_silver_searcher\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"full_name\": \"ripgrep\"") != null);
    // And the alias is recorded under the formula, which is what maps a row
    // back to the name to declare.
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"ag\"") != null);
}

test "brew: a cask resolves through the same query, under its own key" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    const tokens = try rawLines(a, io, &.{ "brew", "list", "--cask", "--full-name" });
    const token = if (tokens.len > 0) tokens[0] else {
        std.debug.print("brew: no cask installed here; the cask resolution check has nothing to ask about\n", .{});
        return error.SkipZigTest;
    };

    const res = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--cask", "--", token });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("brew info --json=v2 --cask did not answer; a cask row cannot be resolved\n", .{});
        return error.TestUnexpectedResult;
    }
    const want = try std.fmt.allocPrint(a, "\"full_token\": \"{s}\"", .{token});
    try testing.expect(std.mem.indexOf(u8, res.stdout, want) != null);
}

test "brew: a batch carrying one unresolvable name answers for none of them" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // The premise of asking each name on its own when a batch fails. If brew
    // ever starts answering for the names it does have, the per-name pass
    // becomes dead weight and this says so.
    const batch = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "ag", "zzz-removed-formula" });
    if (batch.term == .exited and batch.term.exited == 0) {
        std.debug.print("brew info --json=v2 -- ag zzz-removed-formula now exits 0; the per-name pass may no longer be needed\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, batch.stdout, " \t\r\n").len);

    // And each name on its own is answered, which is what the fallback rests
    // on: the good one resolves, the bad one does not.
    const good = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "ag" });
    if (good.term != .exited or good.term.exited != 0) {
        std.debug.print("brew info --json=v2 -- ag did not answer on its own; one bad name would disable alias refusal for a whole batch\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.indexOf(u8, good.stdout, "\"full_name\": \"the_silver_searcher\"") != null);

    const bad = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "zzz-removed-formula" });
    try testing.expect(bad.term != .exited or bad.term.exited != 0);
}

test "brew: a formula and a cask of one name resolve to different packages" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // The premise of one resolution map per kind. `docker` is a canonical
    // formula name and an old token of the cask `docker-desktop`; `dash` is a
    // canonical cask token and an old name of the formula `dash-shell`. One
    // shared map would let whichever kind was asked first answer for the
    // other, and the row of the other kind would install a package under a
    // name brew reports differently.
    const formula = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "docker", "dash" });
    if (formula.term != .exited or formula.term.exited != 0) {
        std.debug.print("brew info --json=v2 --formula -- docker dash did not answer; the collision premise cannot be checked\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.indexOf(u8, formula.stdout, "\"full_name\": \"docker\"") != null);
    try testing.expect(std.mem.indexOf(u8, formula.stdout, "\"full_name\": \"dash-shell\"") != null);

    const cask = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--cask", "--", "docker", "dash" });
    if (cask.term != .exited or cask.term.exited != 0) {
        std.debug.print("brew info --json=v2 --cask -- docker dash did not answer; the collision premise cannot be checked\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.indexOf(u8, cask.stdout, "\"full_token\": \"docker-desktop\"") != null);
    try testing.expect(std.mem.indexOf(u8, cask.stdout, "\"full_token\": \"dash\"") != null);
}

test "brew: a core tap qualifier resolves to the bare name brew reports back" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // The premise of asking about a tap-qualified row: brew answers for
    // `homebrew/core`, whose formulae `brew list --full-name` reports BARE,
    // so such a row would read as missing for ever.
    const core = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "homebrew/core/ripgrep" });
    if (core.term != .exited or core.term.exited != 0) {
        std.debug.print("brew info --json=v2 -- homebrew/core/ripgrep no longer answers; the tap-qualified refusal rests on it\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.indexOf(u8, core.stdout, "\"full_name\": \"ripgrep\"") != null);
    try testing.expect(std.mem.indexOf(u8, core.stdout, "\"tap\": \"homebrew/core\"") != null);

    // And a tap this machine does not have answers nothing at all, which is
    // what keeps such a row: declaring it is the decision to trust the tap.
    const unknown = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", "zzzowner/zzztap/thing" });
    if (unknown.term == .exited and unknown.term.exited == 0) {
        std.debug.print("brew answered for a tap that is not installed; a row naming a new tap would now be judged against it\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "brew: a third-party tap's formula is reported under its qualified name" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);

    // The other half: a row qualifying a tap that is NOT one of brew's
    // defaults resolves to its own spelling, so it must not be refused.
    // Read-only -- the tap is whichever one this machine already has.
    const taps = try rawLines(a, io, &.{ "brew", "tap" });
    var third: ?[]const u8 = null;
    for (taps) |t| {
        if (std.mem.startsWith(u8, t, "homebrew/")) continue;
        third = t;
        break;
    }
    const tap = third orelse {
        std.debug.print("brew: no third-party tap here; the qualified-name check has nothing to ask about\n", .{});
        return error.SkipZigTest;
    };

    const listed = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--formula" });
    var qualified: ?[]const u8 = null;
    const prefix = try std.fmt.allocPrint(a, "{s}/", .{tap});
    for (listed) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        qualified = name;
        break;
    }
    const name = qualified orelse {
        std.debug.print("brew: nothing from {s} is installed; the qualified-name check has nothing to ask about\n", .{tap});
        return error.SkipZigTest;
    };

    const res = try runBrew(a, io, &.{ "brew", "info", "--json=v2", "--formula", "--", name });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("brew info --json=v2 -- {s} did not answer; a tapped row cannot be resolved\n", .{name});
        return error.TestUnexpectedResult;
    }
    // brew reports it qualified, so the row already spells what brew answers
    // with and nothing is refused.
    const want = try std.fmt.allocPrint(a, "\"full_name\": \"{s}\"", .{name});
    try testing.expect(std.mem.indexOf(u8, res.stdout, want) != null);
}
