const std = @import("std");
const toml = @import("toml");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
pub const Record = std.StringHashMap(Value);
pub const ArrayMap = std.StringHashMap([]Record);

/// Errors surfaced when loading a for-loop data source. `TomlParseError` and
/// `NestingTooDeep` come from the underlying TOML parser; `OutOfMemory` from
/// the projection into the `Record`/`ArrayMap` view.
pub const ParseError = toml.Error;

/// Parse a TOML data source and project its top-level `[[name]]`
/// array-of-tables into an `ArrayMap` keyed by table name. Each element table
/// becomes a `Record` of its scalar fields.
///
/// Field projection: string/int/bool map to the matching `Value` variant;
/// float, date, time, and datetime are stringified to their scalar text; an
/// array of scalars becomes `array_of_strings`. A non-scalar field (a nested
/// table, or an array containing a table/array) is not interpolable and is
/// omitted from the record, matching the DSL lint that forbids interpolating
/// non-scalars. Top-level keys that are not an array-of-tables are ignored;
/// only `[[name]]` sections are data sources.
///
/// Returned records and strings are owned by `arena`.
pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!ArrayMap {
    var result = ArrayMap.init(arena);

    const doc = try toml.parse(arena, src, .{});
    if (doc != .table) return result;

    var it = doc.table.iterator();
    while (it.next()) |entry| {
        const tv = entry.value_ptr.*;
        if (tv != .array) continue;
        const elems = tv.array.items;
        if (elems.len == 0) {
            // An empty array is a valid ZERO-ROW loop source: record it as such
            // so `for entry in ...` yields no rows, instead of dropping it and
            // failing as DataSourceArrayNotFound (indistinguishable from a
            // genuinely missing array). A machine with no rows -- e.g. no extra
            // git identities -- then composes to empty, not a compose error.
            try result.put(entry.key_ptr.*, try arena.alloc(Record, 0));
            continue;
        }
        for (elems) |el| {
            if (el != .table) break;
        } else {
            const records = try arena.alloc(Record, elems.len);
            for (elems, 0..) |el, i| {
                records[i] = try projectTable(arena, el.table);
            }
            try result.put(entry.key_ptr.*, records);
        }
    }

    return result;
}

/// Build a `Record` from a TOML table, dropping non-interpolable fields.
fn projectTable(arena: std.mem.Allocator, table: toml.Value.Table) ParseError!Record {
    var record = Record.init(arena);
    var it = table.iterator();
    while (it.next()) |entry| {
        if (try projectValue(arena, entry.value_ptr.*)) |v| {
            try record.put(entry.key_ptr.*, v);
        }
    }
    return record;
}

/// Project a TOML value into a data `Value`, or null when it is not a scalar
/// or scalar array (nested table, or array with a non-scalar element).
fn projectValue(arena: std.mem.Allocator, tv: toml.Value) ParseError!?Value {
    return switch (tv) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .int = i },
        .boolean => |b| .{ .bool = b },
        .float, .datetime, .date, .time => .{ .string = (try scalarText(arena, tv)).? },
        .array => |arr| projectArray(arena, arr),
        .table => null,
    };
}

/// Project a TOML array into `array_of_strings` when every element is a
/// scalar; null when any element is itself an array or table.
fn projectArray(arena: std.mem.Allocator, arr: toml.Value.Array) ParseError!?Value {
    var items = try arena.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |el, i| {
        items[i] = (try scalarText(arena, el)) orelse return null;
    }
    return .{ .array_of_strings = items };
}

/// The scalar text of a TOML value, or null when it is not a scalar. Strings
/// pass through; numbers/bools/dates format to their canonical TOML text.
pub fn scalarText(arena: std.mem.Allocator, tv: toml.Value) ParseError!?[]const u8 {
    return switch (tv) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .boolean => |b| if (b) "true" else "false",
        // `{d}` drops the fractional part of an integral float (1.0 -> "1"),
        // which is a TOML integer, not a float. Re-add the `.0` so an integral
        // finite float stays float-shaped; non-integral and non-finite (nan,
        // inf) values already render with a `.` or letters.
        .float => |f| if (std.math.isFinite(f) and @floor(f) == f)
            try std.fmt.allocPrint(arena, "{d}.0", .{f})
        else
            try std.fmt.allocPrint(arena, "{d}", .{f}),
        .date => |d| try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .time => |t| try formatTime(arena, t),
        .datetime => |dt| try formatDateTime(arena, dt),
        .array, .table => null,
    };
}

fn formatTime(arena: std.mem.Allocator, t: toml.Time) ParseError![]const u8 {
    if (t.nanos == 0)
        return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{ t.hour, t.minute, t.second, t.nanos });
}

fn formatDateTime(arena: std.mem.Allocator, dt: toml.DateTime) ParseError![]const u8 {
    const date = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ dt.date.year, dt.date.month, dt.date.day });
    const time = try formatTime(arena, dt.time);
    if (dt.tz_offset_minutes) |off| {
        if (off == 0) return std.fmt.allocPrint(arena, "{s}T{s}Z", .{ date, time });
        const sign: u8 = if (off < 0) '-' else '+';
        const abs: u32 = @abs(off);
        return std.fmt.allocPrint(arena, "{s}T{s}{c}{d:0>2}:{d:0>2}", .{ date, time, sign, abs / 60, abs % 60 });
    }
    return std.fmt.allocPrint(arena, "{s}T{s}", .{ date, time });
}

test "parse: array of tables with strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[abbreviations]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n");
    const arr = result.get("abbreviations").?;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqualStrings("ll", arr[0].get("key").?.string);
}

test "parse: an empty array is a zero-row source, present in the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "things = []\n");
    // Present (not dropped) so `for` finds it, and yields zero rows.
    const arr = result.get("things");
    try std.testing.expect(arr != null);
    try std.testing.expectEqual(@as(usize, 0), arr.?.len);
    // A genuinely absent array is still absent (distinct from empty).
    try std.testing.expect(result.get("absent") == null);
}

test "parse: multiple table entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[entries]]\nname = \"a\"\n\n[[entries]]\nname = \"b\"\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("a", arr[0].get("name").?.string);
    try std.testing.expectEqualStrings("b", arr[1].get("name").?.string);
}

test "parse: int and bool values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[entries]]\nname = \"foo\"\npriority = -3\nenabled = true\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqual(@as(i64, -3), arr[0].get("priority").?.int);
    try std.testing.expectEqual(true, arr[0].get("enabled").?.bool);
}

test "parse: comments and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "# top\n[[entries]]  # header\nname = \"foo\"  # inline\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqualStrings("foo", arr[0].get("name").?.string);
}

test "parse: stores string arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[entries]]\nkey = \"x\"\nshells = [\"fish\", \"zsh\"]\nexpansion = \"y\"\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const shells = arr[0].get("shells").?;
    try std.testing.expect(shells == .array_of_strings);
    try std.testing.expectEqual(@as(usize, 2), shells.array_of_strings.len);
    try std.testing.expectEqualStrings("fish", shells.array_of_strings[0]);
    try std.testing.expectEqualStrings("zsh", shells.array_of_strings[1]);
}

test "parse: empty array projects to empty string array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[entries]]\nkey = \"x\"\nshells = []\n");
    const arr = result.get("entries").?;
    const shells = arr[0].get("shells").?;
    try std.testing.expect(shells == .array_of_strings);
    try std.testing.expectEqual(@as(usize, 0), shells.array_of_strings.len);
}

test "parse: nested-table field is omitted (non-interpolable)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[[entries]]\nkey = \"x\"\n[entries.meta]\nauthor = \"a\"\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqualStrings("x", arr[0].get("key").?.string);
    try std.testing.expect(arr[0].get("meta") == null);
}

test "parse: plain top-level table is not a data source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "[user]\nname = \"foo\"\n");
    try std.testing.expect(result.get("user") == null);
}

test "parse: float, date, hex, and underscored int project correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(
        arena.allocator(),
        "[[entries]]\npriority = 3.14\nd = 2024-01-15\nh = 0x10\nn = 1_000\n",
    );
    const r = result.get("entries").?[0];
    // Float and date have no dedicated Value variant; they project to their
    // canonical scalar text (previously misparsed to 3 and 2024).
    try std.testing.expectEqualStrings("3.14", r.get("priority").?.string);
    try std.testing.expectEqualStrings("2024-01-15", r.get("d").?.string);
    // Hex and underscored ints are real integers (previously 0 and 1).
    try std.testing.expectEqual(@as(i64, 16), r.get("h").?.int);
    try std.testing.expectEqual(@as(i64, 1000), r.get("n").?.int);
}

test "parse: integral float keeps a trailing .0, non-integral renders naturally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(
        arena.allocator(),
        "[[entries]]\nwhole = 1.0\nfrac = 2.5\nneg = -3.0\n",
    );
    const r = result.get("entries").?[0];
    // An integral float is TOML-canonical with the `.0`, distinguishing it from
    // the integer 1; a non-integral float renders as written.
    try std.testing.expectEqualStrings("1.0", r.get("whole").?.string);
    try std.testing.expectEqualStrings("2.5", r.get("frac").?.string);
    try std.testing.expectEqualStrings("-3.0", r.get("neg").?.string);
}

test "parse: bareword-prefixed bool is a parse error, not a silent true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Previously `trueish` misparsed to bool true with the tail dropped.
    try std.testing.expectError(error.TomlParseError, parse(arena.allocator(), "[[entries]]\nx = trueish\n"));
}

test "parse: trailing junk after a string is a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.TomlParseError, parse(arena.allocator(), "[[entries]]\nk = \"a\" junk\n"));
}

test "parse: unterminated string errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.TomlParseError, parse(arena.allocator(), "[[entries]]\nname = \"unterminated\n"));
}
