//! First-run facts interview.
//!
//! A repo may declare the user facts it needs in `data/facts-schema.toml`:
//!
//!   [[fact]]
//!   name = "profile"
//!   prompt = "Profile (personal/work)"
//!   default = "personal"
//!
//!   [[fact]]
//!   name = "gdrive_account"
//!   prompt = "Google Drive account"
//!   when = "cloud_backend=gdrive"
//!
//! On apply, facts that are declared but not yet bound are prompted for on
//! a TTY and persisted to the machine-local facts file, so a fresh machine
//! is interviewed exactly once. `when` uses the v1 axis-expression grammar
//! and is evaluated against the bindings accumulated so far (axes, existing
//! facts, and answers given earlier in the same interview) — facts are
//! walked in schema order, so a `when` may only reference earlier facts.

const std = @import("std");
const toml = @import("toml");
const dsl = @import("../dsl/root.zig");
const state_mod = @import("state.zig");

const Io = std.Io;

const max_schema_bytes: usize = 256 * 1024;

pub const SchemaFact = struct {
    name: []const u8,
    prompt: []const u8,
    default: ?[]const u8 = null,
    when: ?[]const u8 = null,
};

pub const Outcome = struct {
    /// Facts answered during this walk (interactive input present).
    answers: []const state_mod.Fact = &.{},
    /// Facts that need answers but had no input to draw from
    /// (non-interactive mode). Dependents of an unanswered gate are not
    /// listed; they surface once the gate is answered.
    unanswered: []const SchemaFact = &.{},
};

/// Load `<repo>/data/facts-schema.toml`. Missing file: empty schema.
pub fn loadSchema(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) ![]const SchemaFact {
    const path = try std.fs.path.join(arena, &.{ repo_dir, "data", "facts-schema.toml" });
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_schema_bytes)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const v = try toml.parse(arena, content, .{});
    if (v != .table) return error.InvalidFactsSchema;
    const facts_v = v.table.get("fact") orelse return &.{};
    if (facts_v != .array) return error.InvalidFactsSchema;

    var out: std.ArrayList(SchemaFact) = .empty;
    errdefer out.deinit(arena);
    for (facts_v.array.items) |item| {
        if (item != .table) return error.InvalidFactsSchema;
        const name = stringField(item, "name") orelse return error.InvalidFactsSchema;
        const prompt = stringField(item, "prompt") orelse return error.InvalidFactsSchema;
        try out.append(arena, .{
            .name = name,
            .prompt = prompt,
            .default = stringField(item, "default"),
            .when = stringField(item, "when"),
        });
    }
    return out.toOwnedSlice(arena);
}

fn stringField(v: toml.Value, key: []const u8) ?[]const u8 {
    const field = v.table.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

/// Walk the schema in order against `base_bindings`. Already-bound facts
/// are skipped; a false `when` skips; the rest are prompted through
/// `input`/`prompt_out` when present, or reported as unanswered when not.
pub fn walk(
    arena: std.mem.Allocator,
    schema: []const SchemaFact,
    base_bindings: *const std.StringHashMap([]const u8),
    input: ?*Io.Reader,
    prompt_out: ?*Io.Writer,
) !Outcome {
    var working = std.StringHashMap([]const u8).init(arena);
    var base_it = base_bindings.iterator();
    while (base_it.next()) |e| try working.put(e.key_ptr.*, e.value_ptr.*);

    var answers: std.ArrayList(state_mod.Fact) = .empty;
    var unanswered: std.ArrayList(SchemaFact) = .empty;

    for (schema) |fact| {
        if (working.contains(fact.name)) continue;
        if (fact.when) |expr_src| {
            const expr = try dsl.axis.parseString(arena, expr_src);
            if (!dsl.axis.evaluate(expr, &working)) continue;
        }
        const in = input orelse {
            try unanswered.append(arena, fact);
            continue;
        };
        const value = try ask(arena, fact, in, prompt_out);
        try answers.append(arena, .{ .name = fact.name, .value = value });
        try working.put(fact.name, value);
    }

    return .{
        .answers = try answers.toOwnedSlice(arena),
        .unanswered = try unanswered.toOwnedSlice(arena),
    };
}

fn ask(arena: std.mem.Allocator, fact: SchemaFact, input: *Io.Reader, prompt_out: ?*Io.Writer) ![]const u8 {
    // Hard bound on re-asks: a no-default fact re-prompts on blank answers,
    // and the bound turns no-progress input into an error instead of a spin.
    // takeDelimiter consumes the delimiter; the -Exclusive variant does not
    // and would yield "" here forever.
    var attempts: usize = 0;
    while (attempts < max_ask_attempts) : (attempts += 1) {
        if (prompt_out) |w| {
            if (fact.default) |d| {
                try w.print("{s} ({s}) [{s}]: ", .{ fact.name, fact.prompt, d });
            } else {
                try w.print("{s} ({s}): ", .{ fact.name, fact.prompt });
            }
            try w.flush();
        }
        const line = (try input.takeDelimiter('\n')) orelse
            return fact.default orelse error.InterviewInputClosed;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return arena.dupe(u8, trimmed);
        if (fact.default) |d| return d;
        // No default and empty answer: ask again.
    }
    return error.InterviewInputStalled;
}

const max_ask_attempts = 100;

/// True when `s` holds a C0 control byte (newline, CR, tab, ...) or DEL. Such
/// a byte in a fact value would inject a line into / break the parse of
/// facts.toml, so it is rejected rather than written raw.
fn hasControlChar(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}

/// True when `name` is a valid fact name: a non-empty TOML bare key
/// (`[A-Za-z0-9_-]`). A name is written UNQUOTED as `name = "..."` and also
/// becomes an axis and a `MOX_FACT_<NAME>` env var, so a space, `=`, `"`, `#`,
/// `[`, or `.` would produce invalid TOML that breaks every later facts load.
fn isValidFactName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// True when `name`/`value` could be written by `persist` without either
/// being refused: see `isValidFactName` and `hasControlChar`. Lets a caller
/// that is ABOUT to route an edit to a fact check first, rather than
/// discover the refusal only once other writes may already be applied.
pub fn canPersist(name: []const u8, value: []const u8) bool {
    return isValidFactName(name) and !hasControlChar(value);
}

/// Persist `answers` into the machine-local facts file, replacing any
/// existing assignments of the same names and preserving everything else
/// (comments included). A name or value carrying a control character is
/// refused (`error.InvalidFactName` / `error.InvalidFactValue`) before any
/// write, so a single bad value cannot corrupt the whole file.
pub fn persist(arena: std.mem.Allocator, io: Io, facts_path: []const u8, answers: []const state_mod.Fact) !void {
    if (answers.len == 0) return;

    for (answers) |ans| {
        if (!isValidFactName(ans.name)) return error.InvalidFactName;
        if (hasControlChar(ans.value)) return error.InvalidFactValue;
    }

    const existing = Io.Dir.cwd().readFileAlloc(io, facts_path, arena, .limited(max_schema_bytes)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        if (assignedName(line)) |name| {
            if (findAnswer(answers, name) != null) continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    for (answers) |a| {
        try out.appendSlice(arena, a.name);
        try out.appendSlice(arena, " = \"");
        for (a.value) |c| switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            else => try out.append(arena, c),
        };
        try out.appendSlice(arena, "\"\n");
    }

    if (std.fs.path.dirname(facts_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = out.items });
}

/// Remove `name`'s assignment from the machine-local facts file, leaving
/// everything else (including comments) intact. A missing file, or a name
/// with no assignment, is a no-op. Used to roll a fact write back to "never
/// set" when the name did not exist before it was written.
pub fn remove(arena: std.mem.Allocator, io: Io, facts_path: []const u8, name: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, facts_path, arena, .limited(max_schema_bytes)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        if (assignedName(line)) |n| {
            if (std.mem.eql(u8, n, name)) continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = out.items });
}

fn assignedName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const name = std.mem.trim(u8, line[0..eq], " \t");
    if (name.len == 0 or name[0] == '#') return null;
    return name;
}

fn findAnswer(answers: []const state_mod.Fact, name: []const u8) ?[]const u8 {
    for (answers) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

test "walk: bound facts skipped, dependent when follows earlier answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]SchemaFact{
        .{ .name = "os", .prompt = "never asked" },
        .{ .name = "cloud_backend", .prompt = "backend", .default = "icloud" },
        .{ .name = "gdrive_account", .prompt = "account", .when = "cloud_backend=gdrive" },
        .{ .name = "email", .prompt = "email" },
    };
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    var input = Io.Reader.fixed("gdrive\nme@example.com\nada@example.com\n");
    const outcome = try walk(arena.allocator(), &schema, &bindings, &input, null);

    try std.testing.expectEqual(@as(usize, 3), outcome.answers.len);
    try std.testing.expectEqualStrings("cloud_backend", outcome.answers[0].name);
    try std.testing.expectEqualStrings("gdrive", outcome.answers[0].value);
    try std.testing.expectEqualStrings("gdrive_account", outcome.answers[1].name);
    try std.testing.expectEqualStrings("me@example.com", outcome.answers[1].value);
    try std.testing.expectEqualStrings("email", outcome.answers[2].name);
}

test "walk: empty answer takes the default; false when skips dependent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]SchemaFact{
        .{ .name = "cloud_backend", .prompt = "backend", .default = "icloud" },
        .{ .name = "gdrive_account", .prompt = "account", .when = "cloud_backend=gdrive" },
    };
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    var input = Io.Reader.fixed("\n");
    const outcome = try walk(arena.allocator(), &schema, &bindings, &input, null);

    try std.testing.expectEqual(@as(usize, 1), outcome.answers.len);
    try std.testing.expectEqualStrings("icloud", outcome.answers[0].value);
}

test "walk: non-interactive reports unanswered, hides dependents of unanswered gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]SchemaFact{
        .{ .name = "cloud_backend", .prompt = "backend", .default = "icloud" },
        .{ .name = "gdrive_account", .prompt = "account", .when = "cloud_backend=gdrive" },
    };
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const outcome = try walk(arena.allocator(), &schema, &bindings, null, null);
    try std.testing.expectEqual(@as(usize, 0), outcome.answers.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.unanswered.len);
    try std.testing.expectEqualStrings("cloud_backend", outcome.unanswered[0].name);
}

test "persist: replaces existing assignment, keeps comments, escapes quotes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "# my facts\nprofile = \"personal\"\nlocale = \"en_US.UTF-8\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd_path = try std.process.currentPathAlloc(io, arena.allocator());
    const facts_path = try std.fs.path.join(arena.allocator(), &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });

    const answers = [_]state_mod.Fact{
        .{ .name = "profile", .value = "work" },
        .{ .name = "note", .value = "say \"hi\"" },
    };
    try persist(arena.allocator(), io, facts_path, &answers);

    const written = try Io.Dir.cwd().readFileAlloc(io, facts_path, arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings(
        "# my facts\nlocale = \"en_US.UTF-8\"\nprofile = \"work\"\nnote = \"say \\\"hi\\\"\"\n",
        written,
    );
}

test "persist: a control character in a value or name is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const facts_path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", "no-such-facts-xyz.toml" });

    const bad_value = [_]state_mod.Fact{.{ .name = "note", .value = "a\nadmin = 1" }};
    try std.testing.expectError(error.InvalidFactValue, persist(a, std.testing.io, facts_path, &bad_value));

    const bad_name = [_]state_mod.Fact{.{ .name = "a\nb", .value = "ok" }};
    try std.testing.expectError(error.InvalidFactName, persist(a, std.testing.io, facts_path, &bad_name));

    // Nothing was written.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, facts_path, .{}));
}

test "remove: drops only the named assignment, keeps comments and other facts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "# my facts\nprofile = \"personal\"\nemail = \"a@b.com\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd_path = try std.process.currentPathAlloc(io, arena.allocator());
    const facts_path = try std.fs.path.join(arena.allocator(), &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });

    try remove(arena.allocator(), io, facts_path, "email");

    const written = try Io.Dir.cwd().readFileAlloc(io, facts_path, arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings("# my facts\nprofile = \"personal\"\n", written);
}

test "remove: a missing file or an absent name is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const facts_path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", "no-such-facts-remove.toml" });

    try remove(a, std.testing.io, facts_path, "email");
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, facts_path, .{}));
}

test "isValidFactName: bare-key charset only, so a name cannot break the TOML" {
    try std.testing.expect(isValidFactName("cloud_backend"));
    try std.testing.expect(isValidFactName("signing-work-key"));
    try std.testing.expect(isValidFactName("os2"));
    try std.testing.expect(!isValidFactName("")); // empty
    try std.testing.expect(!isValidFactName("a b")); // space -> `a b = ..` invalid
    try std.testing.expect(!isValidFactName("a=b")); // `=` breaks the assignment
    try std.testing.expect(!isValidFactName("a\"b")); // quote
    try std.testing.expect(!isValidFactName("a.b")); // dotted key is a table path
    try std.testing.expect(!isValidFactName("[x]")); // section header
}

test "canPersist: rejects exactly what persist itself would refuse" {
    try std.testing.expect(canPersist("email", "team@work.com"));
    try std.testing.expect(!canPersist("email", "a\tb"));
    try std.testing.expect(!canPersist("email", "a\nadmin = 1"));
    try std.testing.expect(!canPersist("a.b", "ok"));
    try std.testing.expect(!canPersist("", "ok"));
}

test "loadSchema: missing file yields empty schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try loadSchema(arena.allocator(), std.testing.io, "/nonexistent-repo-xyz");
    try std.testing.expectEqual(@as(usize, 0), schema.len);
}

test "ask: EOF on a no-default fact errors instead of hanging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]SchemaFact{
        .{ .name = "email", .prompt = "email" },
    };
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    var input = Io.Reader.fixed("");
    try std.testing.expectError(
        error.InterviewInputClosed,
        walk(arena.allocator(), &schema, &bindings, &input, null),
    );
}

test "ask: blank-line answers on a no-default fact are bounded, not infinite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]SchemaFact{
        .{ .name = "email", .prompt = "email" },
    };
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const blanks = "\n" ** (max_ask_attempts + 5);
    var input = Io.Reader.fixed(blanks);
    try std.testing.expectError(
        error.InterviewInputStalled,
        walk(arena.allocator(), &schema, &bindings, &input, null),
    );
}
