const std = @import("std");
const testing = std.testing;

pub const Rule = struct {
    pattern: []const u8,
    negated: bool,
    anchored: bool,
    dir_only: bool,
};

pub const RuleSet = struct {
    rules: []const Rule,

    pub fn isIgnored(self: RuleSet, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.rules) |r| {
            if (r.dir_only and !is_dir) continue;
            if (matchRule(r, rel_path)) ignored = !r.negated;
        }
        return ignored;
    }

    /// True if `rel` (home-relative, '/'-separated, no leading '/') is ignored
    /// directly, or by virtue of any ancestor directory matching a rule.
    /// `leaf_is_dir` is the kind of the leaf itself.
    pub fn isPathIgnored(self: RuleSet, rel: []const u8, leaf_is_dir: bool) bool {
        if (self.isIgnored(rel, leaf_is_dir)) return true;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
            if (self.isIgnored(rel[0..slash], true)) return true;
            i = slash + 1;
        }
        return false;
    }
};

/// Parse `text` (newline-separated) into rules. Blank lines and lines whose
/// first non-space byte is `#` are skipped (a literal leading `#` is written
/// `\#`). Trailing spaces are trimmed unless backslash-escaped; keep it simple
/// here and trim unescaped trailing ASCII space/tab.
pub fn compile(arena: std.mem.Allocator, text: []const u8) !RuleSet {
    var list: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw0| {
        const raw = std.mem.trimEnd(u8, raw0, " \t\r");
        var line = std.mem.trimStart(u8, raw, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "\\#")) line = line[1..];

        var negated = false;
        if (line.len > 0 and line[0] == '!') {
            negated = true;
            line = line[1..];
        }
        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        var anchored = false;
        if (line.len > 0 and line[0] == '/') {
            anchored = true;
            line = line[1..];
        }
        if (line.len == 0) continue;
        try list.append(arena, .{
            .pattern = try arena.dupe(u8, line),
            .negated = negated,
            .anchored = anchored,
            .dir_only = dir_only,
        });
    }
    return .{ .rules = try list.toOwnedSlice(arena) };
}

fn matchRule(r: Rule, path: []const u8) bool {
    const has_slash = std.mem.indexOfScalar(u8, r.pattern, '/') != null;
    if (r.anchored or has_slash) {
        return globSegments(r.pattern, path);
    }
    // Unanchored, no slash: match the basename, or any single path component.
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (globToken(r.pattern, seg)) return true;
    }
    return false;
}

/// Match a `/`-split pattern against a `/`-split path. A `**` segment matches
/// zero or more path segments; a `**` at the tail matches everything below.
fn globSegments(pattern: []const u8, path: []const u8) bool {
    var p_it = std.mem.splitScalar(u8, pattern, '/');
    var pats: [64][]const u8 = undefined;
    var np: usize = 0;
    while (p_it.next()) |seg| : (np += 1) {
        if (np == pats.len) return false;
        pats[np] = seg;
    }
    var segs: [128][]const u8 = undefined;
    var ns: usize = 0;
    var s_it = std.mem.splitScalar(u8, path, '/');
    while (s_it.next()) |seg| : (ns += 1) {
        if (ns == segs.len) return false;
        segs[ns] = seg;
    }
    return segMatch(pats[0..np], segs[0..ns]);
}

fn segMatch(pats: []const []const u8, segs: []const []const u8) bool {
    if (pats.len == 0) return segs.len == 0;
    if (std.mem.eql(u8, pats[0], "**")) {
        // `**` matches zero or more segments; try each split, and also match
        // when it is the final pattern segment (ignore everything below).
        if (pats.len == 1) return true;
        var i: usize = 0;
        while (i <= segs.len) : (i += 1) {
            if (segMatch(pats[1..], segs[i..])) return true;
        }
        return false;
    }
    if (segs.len == 0) return false;
    if (!globToken(pats[0], segs[0])) return false;
    return segMatch(pats[1..], segs[1..]);
}

/// Match one path component against one pattern component: `*` (any run, no
/// `/`), `?` (one char), `[...]` class, everything else literal.
fn globToken(pat: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;
    while (ni < name.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (pi < pat.len and pat[pi] == '?') {
            pi += 1;
            ni += 1;
        } else if (pi < pat.len and pat[pi] == '[') {
            const consumed = matchClass(pat[pi..], name[ni]);
            if (consumed == 0) {
                if (star_pi) |sp| {
                    pi = sp + 1;
                    star_ni += 1;
                    ni = star_ni;
                } else return false;
            } else {
                pi += consumed;
                ni += 1;
            }
        } else if (pi < pat.len and pat[pi] == name[ni]) {
            pi += 1;
            ni += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

/// If `pat` starts with a `[...]` class matching `c`, return bytes consumed
/// (past the closing `]`); else 0.
fn matchClass(pat: []const u8, c: u8) usize {
    std.debug.assert(pat[0] == '[');
    var i: usize = 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    while (i < pat.len and pat[i] != ']') {
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (c >= pat[i] and c <= pat[i + 2]) matched = true;
            i += 3;
        } else {
            if (c == pat[i]) matched = true;
            i += 1;
        }
    }
    if (i >= pat.len) return 0; // unterminated class: no match
    const consumed = i + 1; // include ']'
    return if (matched != negate) consumed else 0;
}

test "compile: skips blanks and comments, records flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const set = try compile(a,
        \\# a comment
        \\
        \\*.jsonl
        \\/anchored
        \\projects/
        \\!keep.jsonl
        \\
    );
    try testing.expectEqual(@as(usize, 4), set.rules.len);
    try testing.expectEqualStrings("*.jsonl", set.rules[0].pattern);
    try testing.expect(!set.rules[0].anchored and !set.rules[0].dir_only and !set.rules[0].negated);
    try testing.expect(set.rules[1].anchored);
    try testing.expectEqualStrings("anchored", set.rules[1].pattern);
    try testing.expect(set.rules[2].dir_only);
    try testing.expectEqualStrings("projects", set.rules[2].pattern);
    try testing.expect(set.rules[3].negated);
    try testing.expectEqualStrings("keep.jsonl", set.rules[3].pattern);
}

fn ig(a: std.mem.Allocator, text: []const u8, path: []const u8, is_dir: bool) !bool {
    const set = try compile(a, text);
    return set.isIgnored(path, is_dir);
}

test "match: unanchored basename matches at any depth" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, "*.jsonl", ".claude/projects/x.jsonl", false));
    try testing.expect(try ig(a, "id_rsa", ".ssh/id_rsa", false));
    try testing.expect(!try ig(a, "id_rsa", ".ssh/id_rsa.pub", false));
}

test "match: anchored matches from root only" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, "/CLAUDE.md", "CLAUDE.md", false));
    try testing.expect(!try ig(a, "/CLAUDE.md", "sub/CLAUDE.md", false));
}

test "match: internal-slash pattern is rooted" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, ".claude/*.jsonl", ".claude/a.jsonl", false));
    try testing.expect(!try ig(a, ".claude/*.jsonl", "other/.claude/a.jsonl", false));
}

test "match: double-star spans directories" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, ".claude/**", ".claude/projects/deep/x", false));
    try testing.expect(try ig(a, "**/cache", "a/b/cache", true));
}

test "match: dir-only requires a directory" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, "projects/", ".claude/projects", true));
    try testing.expect(!try ig(a, "projects/", ".claude/projects", false));
}

test "match: negation re-includes, last match wins" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    const text = ".claude/*\n!.claude/CLAUDE.md\n";
    try testing.expect(try ig(a, text, ".claude/settings.json", false));
    try testing.expect(!try ig(a, text, ".claude/CLAUDE.md", false));
}

test "match: question mark and char class" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    try testing.expect(try ig(a, "*.pe?", "key.pem", false));
    try testing.expect(try ig(a, "id_[re]sa", "id_rsa", false));
}

test "isPathIgnored: leaf-file rule matches directly" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    const set = try compile(a, ".claude/.credentials.json\n");
    try testing.expect(set.isPathIgnored(".claude/.credentials.json", false));
}

test "isPathIgnored: a dir-only ancestor rule matches a leaf checked in isolation" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    const set = try compile(a, "foo/\n");
    // isIgnored alone misses this: dir_only is skipped when is_dir is false.
    try testing.expect(!set.isIgnored("foo/bar", false));
    try testing.expect(set.isPathIgnored("foo/bar", false));
}

test "isPathIgnored: a top-level file with no ancestors is unaffected by the walk" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    const set = try compile(a, "*.jsonl\n");
    try testing.expect(set.isPathIgnored("x.jsonl", false));
    try testing.expect(!set.isPathIgnored("x.txt", false));
}

test "isPathIgnored: a directory leaf is matched directly, not just via ancestor walk" {
    var s = std.heap.ArenaAllocator.init(testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    const set = try compile(a, "projects/\n");
    try testing.expect(set.isPathIgnored(".claude/projects", true));
}
