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

/// The most an id or a name may be. Longer says the backend padded its output
/// or lost its line separator (dnf5 concatenates every name when its format
/// string lacks a newline); this catches that for a large set, and the fixture
/// tests catch the rest.
pub const max_shape_bytes: usize = 256;

/// Whether an id has the shape of one id. The class is `nameShapeOk`'s, length
/// included, because `declare` may answer `name = <id>`: an id outside it would
/// become a manifest row the next run refuses to load.
pub fn idShapeOk(id: []const u8) bool {
    if (id.len == 0 or id.len > max_shape_bytes) return false;
    return plainText(id);
}

/// Whether a `name` is one a manifest can carry and a manager can be handed.
/// The single authority on that: the manifest loader refuses a row outside
/// this class, so everything that invents a name -- a plugin's `declare`, an
/// adapter answering with its id -- is held to the same rule before the row is
/// written, and nothing can record a row every later run then refuses. One
/// class in both directions: a name the loader took that no id may be would
/// leave `declare` free to write a row `idOf` can never match back.
pub fn nameShapeOk(name: []const u8) bool {
    if (name.len == 0 or name.len > max_shape_bytes) return false;
    return plainText(name);
}

/// How wide a manager's package namespace is. One shared class cannot serve
/// every manager: apt's own explicit-install query reports a
/// foreign-architecture package as `pkg:arch`, while zypper reads `:` as a
/// selector separator (`pattern:`, `patch:`), which rpm can never read back.
pub const NameClass = enum {
    plain,
    /// A plain name, optionally carrying one `:<arch>` qualifier.
    multiarch,
    /// A Homebrew formula or cask, optionally tap-qualified as
    /// `owner/tap/name`. `@` is in the class because `openssl@3` and
    /// `emacs-plus@30` are real formulae.
    tapped,
    /// One scoop app name. scoop takes the bucket as a field of its own, so
    /// nothing here needs a separator.
    app,
    /// One winget `PackageIdentifier`. Kept wider than `app` deliberately:
    /// winget's identifiers are the publisher's own strings
    /// (`Notepad++.Notepad++`, a bare store id), mox cannot enumerate them,
    /// and a class narrower than winget's would refuse a package someone
    /// really has. So this one names the bytes that make an identifier
    /// something else -- a path, a URL, an option -- rather than the bytes a
    /// name may hold.
    identifier,
};

/// Why a name is not a package name, for an adapter whose manager takes
/// package names as bare operands in its install argv.
pub const NameProblem = enum {
    empty,
    leading,
    character,
    trailing_hyphen,
    arch,
    segments,

    /// The clause a diagnostic states after naming the file and the row.
    pub fn text(self: NameProblem, class: NameClass) []const u8 {
        return switch (self) {
            .empty => "a name cannot be empty",
            .leading => switch (class) {
                .tapped => "a name begins with a letter or a digit, and so does each part of a tap-qualified one",
                else => "a name begins with a letter or a digit",
            },
            .character => switch (class) {
                .plain => "a name holds only letters, digits and \".\", \"_\", \"+\" or \"-\"",
                .multiarch => "a name holds only letters, digits and \".\", \"_\", \"+\" or \"-\", optionally followed by \":\" and an architecture",
                .tapped => "a name holds only letters, digits and \".\", \"_\", \"+\", \"-\" or \"@\"",
                .app => "a name holds only letters, digits and \".\", \"_\", \"+\" or \"-\"",
                .identifier => "an identifier holds none of \"\\\", \"/\", \":\", \"*\", \"?\", \"<\", \">\", \"|\" or a quotation mark, which would make it a path, a URL or a pattern",
            },
            // apt-get reads `nano-` as "remove nano" and zypper reads `-nano`
            // and `!nano` the same way, so a row can otherwise ask mox to
            // uninstall a package on every apply.
            .trailing_hyphen => "a name does not end with \"-\", which an install reads as a request to remove the package",
            .arch => "a name carries one \":\" at most, and an architecture holds only letters, digits and \"-\"",
            // `brew install ./x.rb` installs a local Ruby file, and
            // `owner/tap` alone names a tap rather than anything installable.
            .segments => "a name is one formula or cask, or a tap-qualified \"owner/tap/name\"",
        };
    }
};

/// Whether `name` is a package name of `class`, and if not, which rule it
/// broke.
///
/// An allowlist, because the denylist it replaced could not be finished: an
/// install argv accepts far more than package names -- remove suffixes,
/// selectors, capability expressions, version relations, repository
/// qualifiers -- and the grammar is the manager's to change, not mox's to
/// enumerate. Two distinct harms sit outside this class. A name the manager
/// reads as an operation makes `mox apply` uninstall a package, which mox
/// states it never does; a name the manager resolves to a different package
/// (`pkgconfig(libcrypto)` installs `libressl-devel`) reads back under a name
/// no row matches, so it is MISSING on every status and reinstalled on every
/// apply.
///
/// A trailing `+` stays legal: `g++` is a real package.
///
/// The classes beyond the distro pair answer those same two harms in their
/// own grammars. brew exits 0 on `brew install --help`, so a row named
/// `--help` reads as installed, is reported missing by the query that
/// follows, and is "installed" again on every apply; `brew install ./x.rb`
/// runs a local Ruby file. scoop takes a manifest path or a URL where an app
/// name goes, and `scoop install git@2.1` installs a version that `scoop
/// export` reports under the bare name. winget's identifier is the
/// publisher's own string, so its class names what would make the value a
/// path, a URL or a pattern instead.
pub fn nameProblem(name: []const u8, class: NameClass) ?NameProblem {
    if (name.len == 0) return .empty;
    switch (class) {
        .app => return segmentProblem(name, class),
        .identifier => {
            if (!std.ascii.isAlphanumeric(name[0])) return .leading;
            for (name) |c| {
                switch (c) {
                    '\\', '/', ':', '*', '?', '"', '<', '>', '|' => return .character,
                    else => {},
                }
            }
            return null;
        },
        .tapped => {
            var parts = std.mem.splitScalar(u8, name, '/');
            var count: usize = 0;
            while (parts.next()) |part| {
                count += 1;
                if (count > 3) return .segments;
                if (segmentProblem(part, class)) |p| return p;
            }
            if (count == 2) return .segments;
            return null;
        },
        .plain, .multiarch => {},
    }
    const base = switch (class) {
        .multiarch => blk: {
            const colon = std.mem.indexOfScalar(u8, name, ':') orelse break :blk name;
            if (!isArchitecture(name[colon + 1 ..])) return .arch;
            break :blk name[0..colon];
        },
        else => name,
    };
    if (segmentProblem(base, class)) |p| return p;
    if (base[base.len - 1] == '-') return .trailing_hyphen;
    return null;
}

/// Whether one run of a name -- a whole name, or one `/`-separated part of a
/// tap-qualified one -- holds only what `class` admits.
fn segmentProblem(s: []const u8, class: NameClass) ?NameProblem {
    if (s.len == 0) return .leading;
    if (!std.ascii.isAlphanumeric(s[0])) return .leading;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '.', '_', '+', '-' => {},
            '@' => if (class != .tapped) return .character,
            else => return .character,
        }
    }
    return null;
}

/// How a field value an adapter splices into its manager's argv is read
/// there.
pub const ValueClass = enum {
    /// One operand: a scoop bucket, a winget source.
    token,
    /// A whole command line handed on to something else, which is what
    /// winget's `override` exists to be.
    command_line,
};

/// Why a field value is not one of its class.
///
/// A value is checked because it lands where a name lands. On Windows the
/// harm is worse than an odd operand: Zig serializes an argv for
/// `CommandLineToArgvW`, escaping an embedded `"` by doubling backslashes,
/// while PowerShell's `-File` parser reads `\"` as a backslash and a quote
/// that ENDS quoting -- so a value carrying whitespace and a `"` together
/// leaves its own argv element and becomes several operands of the command
/// it was spliced into. A value with whitespace alone does not: the quoting
/// PowerShell does honour holds it together.
pub const ValueProblem = enum {
    empty,
    leading,
    character,
    quote,
    control,

    /// The clause a diagnostic states after naming the file, the row and the
    /// key.
    pub fn text(self: ValueProblem, class: ValueClass) []const u8 {
        return switch (self) {
            .empty => "cannot be empty",
            .leading => "begins with a letter or a digit",
            .character => switch (class) {
                .token => "holds only letters, digits and \".\", \"_\", \"+\" or \"-\"",
                .command_line => "holds only text",
            },
            .quote => "holds no \" character, which Windows' two command-line parsers disagree about, so a value carrying one can leave its own argument and become several",
            .control => "holds no control byte",
        };
    }
};

/// Whether `v` is a field value of `class`, and if not, which rule it broke.
pub fn valueProblem(v: []const u8, class: ValueClass) ?ValueProblem {
    if (v.len == 0) return .empty;
    if (!std.unicode.utf8ValidateSlice(v)) return .character;
    for (v) |c| {
        if (std.ascii.isControl(c)) return .control;
        if (c == '"') return .quote;
    }
    switch (class) {
        // An installer's own arguments need the space and the slash that a
        // token may not have; only the bytes no argv can carry across both
        // Windows parsers are refused, which is the loop above.
        .command_line => return null,
        .token => {
            if (!std.ascii.isAlphanumeric(v[0])) return .leading;
            for (v) |c| {
                if (std.ascii.isAlphanumeric(c)) continue;
                switch (c) {
                    '.', '_', '+', '-' => {},
                    else => return .character,
                }
            }
            return null;
        },
    }
}

/// Whether `s` has the shape of a dpkg architecture (`amd64`, `armhf`,
/// `kfreebsd-amd64`). Neither `.` nor `+` is one, which keeps a regex
/// metacharacter out of the one part of a name apt does not resolve against
/// its package list.
fn isArchitecture(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-') continue;
        return false;
    }
    return s[s.len - 1] != '-';
}

/// `name` without its `:<arch>` qualifier: the name apt resolves against its
/// package list, and the one `apt-cache pkgnames` lists.
pub fn bareName(name: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return name;
    return name[0..colon];
}

/// The `:<arch>` qualifier `name` carries, or null.
pub fn archOf(name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    return name[colon + 1 ..];
}

/// The architecture suffix `name` carries, or null. rpm reports an
/// arch-qualified spec (`bat.x86_64`, dnf's full NEVRA `bat-0.24.0-1.x86_64`)
/// under its bare name, so a row spelling one installs and then reads as
/// missing forever.
pub fn rpmArchSuffix(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const suffix = name[dot + 1 ..];
    for ([_][]const u8{ "x86_64", "i586", "i686", "aarch64", "armv7hl", "ppc64le", "s390x", "noarch" }) |arch| {
        if (std.mem.eql(u8, suffix, arch)) return arch;
    }
    return null;
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
    /// What this adapter's install checks a row against before running its
    /// manager, named so a dry run can say what it did not check. The check
    /// itself refreshes an index and elevates, which a dry run must not do,
    /// so a row a real apply would refuse is listed as one it would install.
    install_check: ?[]const u8 = null,

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
        /// Whether the last `install` reached the point of running its
        /// manager's install command. Absent for an adapter whose install
        /// runs it first thing, where the answer is always yes.
        installSpawned: ?*const fn (ctx: *anyopaque) bool = null,
        /// How many of the last `install`'s rows the adapter refused without
        /// handing them to its manager. Absent for an adapter that refuses
        /// none, where the answer is always zero.
        installRefused: ?*const fn (ctx: *anyopaque) usize = null,
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

    /// Whether a failed `install` got as far as spawning its manager, so its
    /// rows may have landed. Asked of the adapter, which is the only thing
    /// that knows: the error alone cannot answer it, because a pre-check and
    /// the install itself fail in the same ways -- a query that timed out, an
    /// argv that could not run -- and a pre-check that grows a failure mode
    /// would silently start reporting rows as possibly landed. An adapter
    /// that does not answer is read as having spawned, which over-reports a
    /// changed machine rather than hiding one.
    pub fn installSpawned(self: Backend) bool {
        const f = self.vtable.installSpawned orelse return true;
        return f(self.ctx);
    }

    /// How many rows the last `install` refused rather than handing to its
    /// manager. A refused row is one failure; the rows beside it are
    /// installed, because one bad row in a manifest must not stop every other
    /// package on the machine. The adapter is asked, rather than the count
    /// inferred from the error, because a refusal is no longer an error: an
    /// install that refuses one row of three and installs the other two
    /// returns cleanly.
    pub fn installRefused(self: Backend) usize {
        const f = self.vtable.installRefused orelse return 0;
        return f(self.ctx);
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
}

test "idShapeOk / nameShapeOk: one class, asserted in both directions" {
    // A row an adapter may write is a row the loader will read back, so
    // neither predicate may take what the other refuses -- in either
    // direction, length included: a 257-byte `declare` answer the loader
    // accepted would be written once and refused by every run after.
    const outside = [_][]const u8{
        "",
        " ",
        "gnu make",
        "gnu\tmake",
        "gnu\nmake",
        "gnu\x0bmake",
        "gnu\x0cmake",
        "gnu\x01make",
        "gnu\x7fmake",
        "gnu\xffmake",
        "\xed\xa0\x80",
        "x" ** (max_shape_bytes + 1),
    };
    for (outside) |s| {
        try testing.expect(!idShapeOk(s));
        try testing.expect(!nameShapeOk(s));
    }

    const inside = [_][]const u8{
        "ripgrep",
        "cask:ghostty",
        "emacs-plus@30",
        "日本語",
        "x" ** max_shape_bytes,
    };
    for (inside) |s| {
        try testing.expect(idShapeOk(s));
        try testing.expect(nameShapeOk(s));
    }
}

test "nameProblem: the shapes a manager would read as an operation" {
    // apt's remove form, and the two zypper reads the same way.
    for ([_]NameClass{ .plain, .multiarch }) |class| {
        try testing.expectEqual(NameProblem.trailing_hyphen, nameProblem("nano-", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("!vim", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("-vim", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("+pkg", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("@group", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem(".foo", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("/usr/bin/x", class).?);
        try testing.expectEqual(NameProblem.leading, nameProblem("~pkg", class).?);
        try testing.expectEqual(NameProblem.empty, nameProblem("", class).?);
    }
    // A qualified name is judged on the name, not on the qualifier.
    try testing.expectEqual(NameProblem.trailing_hyphen, nameProblem("nano-:armhf", .multiarch).?);
    try testing.expectEqual(NameProblem.leading, nameProblem(":armhf", .multiarch).?);
}

test "nameProblem: the shapes that resolve to a package of another name" {
    for ([_]NameClass{ .plain, .multiarch }) |class| {
        try testing.expectEqual(NameProblem.character, nameProblem("pkgconfig(libcrypto)", class).?);
        try testing.expectEqual(NameProblem.character, nameProblem("repo/pkg", class).?);
        try testing.expectEqual(NameProblem.character, nameProblem("pkg=1.2", class).?);
        try testing.expectEqual(NameProblem.character, nameProblem("pkg>=1.2", class).?);
        try testing.expectEqual(NameProblem.character, nameProblem("bat,ripgrep", class).?);
        try testing.expectEqual(NameProblem.character, nameProblem("gnu make", class).?);
    }
}

test "nameProblem: a colon is apt's architecture qualifier and zypper's selector" {
    // apt-mark showmanual -- mox's own explicit-install query -- reports a
    // foreign-architecture package as `pkg:arch`, so refusing it leaves drift
    // no command can clear on a multiarch machine. zypper's `pattern:` and
    // `patch:` name things rpm never reports, so a colon stays refused there.
    try testing.expectEqual(@as(?NameProblem, null), nameProblem("libc6:armhf", .multiarch));
    try testing.expectEqual(@as(?NameProblem, null), nameProblem("g++:i386", .multiarch));
    try testing.expectEqual(@as(?NameProblem, null), nameProblem("libc6:kfreebsd-amd64", .multiarch));
    try testing.expectEqual(NameProblem.character, nameProblem("libc6:armhf", .plain).?);
    try testing.expectEqual(NameProblem.character, nameProblem("pattern:devel_basis", .plain).?);
    try testing.expectEqual(NameProblem.character, nameProblem("perl(Foo::Bar)", .plain).?);

    // One qualifier, and nothing in it apt would resolve as a regex or read
    // as an operation.
    try testing.expectEqual(NameProblem.arch, nameProblem("pattern:devel_basis", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("perl(Foo::Bar)", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("libc6:", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("libc6:a:b", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("libc6:arm.f", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("libc6:armhf-", .multiarch).?);
    try testing.expectEqual(NameProblem.arch, nameProblem("libc6:-armhf", .multiarch).?);
}

test "bareName / archOf: the two halves apt keeps apart" {
    try testing.expectEqualStrings("libc6", bareName("libc6:armhf"));
    try testing.expectEqualStrings("libc6", bareName("libc6"));
    try testing.expectEqualStrings("armhf", archOf("libc6:armhf").?);
    try testing.expectEqual(@as(?[]const u8, null), archOf("libc6"));
}

test "nameProblem: the names real distributions ship" {
    // `g++` is why only a trailing `-` is refused and a trailing `+` is not.
    const inside = [_][]const u8{
        "g++",
        "lib32-glibc",
        "python3.11",
        "gcc-c++",
        "zlib1g-dev",
        "perl-Foo-Bar",
        "libstdc++6",
        "ripgrep",
        "7zip",
        "bat",
    };
    for ([_]NameClass{ .plain, .multiarch }) |class| {
        for (inside) |s| try testing.expectEqual(@as(?NameProblem, null), nameProblem(s, class));
    }
}

test "nameProblem: a package name is a name the loader already takes" {
    // The two classes must nest: a name this predicate passes that the
    // manifest loader would refuse could never reach an adapter, and a rule
    // no row can reach is a rule that was never tested.
    const inside = [_][]const u8{ "g++", "lib32-glibc", "python3.11", "libstdc++6" };
    for (inside) |s| {
        try testing.expect(nameShapeOk(s));
        try testing.expect(idShapeOk(s));
    }
}

test "rpmArchSuffix: an arch-qualified spec reads back under its bare name" {
    try testing.expectEqualStrings("x86_64", rpmArchSuffix("bat.x86_64").?);
    try testing.expectEqualStrings("x86_64", rpmArchSuffix("bat-0.24.0-1.x86_64").?);
    try testing.expectEqualStrings("noarch", rpmArchSuffix("tzdata.noarch").?);
    try testing.expectEqualStrings("aarch64", rpmArchSuffix("bat.aarch64").?);

    try testing.expectEqual(@as(?[]const u8, null), rpmArchSuffix("bat"));
    // A dot is ordinary inside a name; only a known arch after the last one
    // is a qualifier.
    try testing.expectEqual(@as(?[]const u8, null), rpmArchSuffix("python3.11"));
    try testing.expectEqual(@as(?[]const u8, null), rpmArchSuffix("bat.x86"));
}

test "nameProblem: a brew name is a formula, a cask, or a tap-qualified one" {
    // What brew really ships: `@` for a versioned formula, `+` for a name
    // like `gtk+3`, and a three-part name for a third-party tap.
    const inside = [_][]const u8{
        "ripgrep",
        "openssl@3",
        "emacs-plus@30",
        "d12frosted/emacs-plus/emacs-plus@30",
        "font-fira-code-nerd-font",
        "7zip",
        "gtk+3",
    };
    for (inside) |s| try testing.expectEqual(@as(?NameProblem, null), nameProblem(s, .tapped));

    // `brew install --help` exits 0, so an option-shaped row would count as
    // installed and be installed again on every apply.
    try testing.expectEqual(NameProblem.leading, nameProblem("--help", .tapped).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("-i", .tapped).?);
    // A local Ruby file is arbitrary code, and brew installs one by path.
    try testing.expectEqual(NameProblem.leading, nameProblem("./evil.rb", .tapped).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("/tmp/evil.rb", .tapped).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("../evil.rb", .tapped).?);
    // A URL installs a formula from anywhere at all.
    try testing.expectEqual(NameProblem.character, nameProblem("https://evil/x.rb", .tapped).?);
    // Two parts name a tap, which nothing installs and no query reports.
    try testing.expectEqual(NameProblem.segments, nameProblem("owner/tap", .tapped).?);
    try testing.expectEqual(NameProblem.segments, nameProblem("a/b/c/d", .tapped).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("owner//name", .tapped).?);
    try testing.expectEqual(NameProblem.empty, nameProblem("", .tapped).?);
}

test "nameProblem: an app name is one token, with no version and no path" {
    const inside = [_][]const u8{
        "ripgrep",
        "nodejs-lts",
        "7zip",
        "Microsoft.PowerShell",
        "Notepad++.Notepad++",
        "JanDeDobbeleer.OhMyPosh",
        "windows_terminal",
    };
    for (inside) |s| try testing.expectEqual(@as(?NameProblem, null), nameProblem(s, .app));

    // `scoop install git@2.1` installs a version that `scoop export` reports
    // under the bare name, so the row reads as missing on every status after.
    try testing.expectEqual(NameProblem.character, nameProblem("git@2.1", .app).?);
    // A bucket belongs in its own field, and a manifest path or a URL is not
    // an app name at all.
    try testing.expectEqual(NameProblem.character, nameProblem("extras/vscode", .app).?);
    try testing.expectEqual(NameProblem.character, nameProblem("https://evil/x.json", .app).?);
    try testing.expectEqual(NameProblem.leading, nameProblem(".\\evil.json", .app).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("--help", .app).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("-g", .app).?);
}

test "valueProblem: a field value spliced into an argv is held to its own class" {
    // The value that breaks out on Windows: Zig serializes an argv for
    // `CommandLineToArgvW` and escapes the `"` as `\"`, which PowerShell's
    // `-File` parser reads as a backslash and the END of quoting -- so this
    // one value becomes several operands of `scoop bucket add`, whose second
    // operand is the bucket's repository URL.
    try testing.expectEqual(ValueProblem.quote, valueProblem("a\" extras https://evil/x\"b", .token).?);
    try testing.expectEqual(ValueProblem.quote, valueProblem("a\" extras https://evil/x\"b", .command_line).?);

    // Whitespace alone does not break out -- PowerShell honours the quoting
    // Zig added -- but a bucket is still one token.
    try testing.expectEqual(ValueProblem.character, valueProblem("extras https://evil/x", .token).?);
    try testing.expectEqual(ValueProblem.leading, valueProblem("-Force", .token).?);
    try testing.expectEqual(ValueProblem.empty, valueProblem("", .token).?);
    try testing.expectEqual(ValueProblem.control, valueProblem("extras\nmain", .token).?);
    for ([_][]const u8{ "extras", "nerd-fonts", "main", "versions", "winget", "msstore" }) |s| {
        try testing.expectEqual(@as(?ValueProblem, null), valueProblem(s, .token));
    }

    // An installer's own arguments need the space, the slash and the dash
    // that a token may not have; only what no argv can carry is refused.
    for ([_][]const u8{ "/SILENT /NORESTART", "-y --quiet", "/DIR=C:\\Program Files\\x" }) |s| {
        try testing.expectEqual(@as(?ValueProblem, null), valueProblem(s, .command_line));
    }
    try testing.expectEqual(ValueProblem.control, valueProblem("/SILENT\r\n/DIR=x", .command_line).?);
    try testing.expectEqual(ValueProblem.empty, valueProblem("", .command_line).?);
}

test "nameProblem: a winget identifier is the publisher's string, minus what makes it something else" {
    // Identifiers mox cannot enumerate and must not refuse: a `+` that a
    // narrow class would reject, a bare store id with no publisher part, a
    // third segment.
    const inside = [_][]const u8{
        "Microsoft.PowerShell",
        "Notepad++.Notepad++",
        "9NBLGGH4NNS1",
        "Mozilla.Firefox.ESR",
        "JanDeDobbeleer.OhMyPosh",
        "M2Team.NanaZip",
    };
    for (inside) |s| try testing.expectEqual(@as(?NameProblem, null), nameProblem(s, .identifier));

    // What would make the value something other than an identifier.
    try testing.expectEqual(NameProblem.leading, nameProblem("--help", .identifier).?);
    try testing.expectEqual(NameProblem.leading, nameProblem("-i", .identifier).?);
    try testing.expectEqual(NameProblem.leading, nameProblem(".\\evil.msi", .identifier).?);
    try testing.expectEqual(NameProblem.character, nameProblem("C:\\x\\evil.msi", .identifier).?);
    try testing.expectEqual(NameProblem.character, nameProblem("https://evil/x.msi", .identifier).?);
    try testing.expectEqual(NameProblem.character, nameProblem("msstore/Git.Git", .identifier).?);
    try testing.expectEqual(NameProblem.character, nameProblem("Git.*", .identifier).?);
    try testing.expectEqual(NameProblem.character, nameProblem("Git\"Git", .identifier).?);
    try testing.expectEqual(NameProblem.empty, nameProblem("", .identifier).?);
}
