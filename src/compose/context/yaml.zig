//! The YAML context tracker: follows double- and single-quoted scalars,
//! plain scalars, block scalars, comments, node properties and flow
//! collections, enough to name the encoding of a capture's position.

const std = @import("std");
const types = @import("types.zig");

const Context = types.Context;

const Mode = enum(u8) {
    /// Between tokens, in block or flow context.
    structural,
    /// `-`, `?`, `:` (or a `---`/`...` marker run) whose role the next
    /// byte decides: an indicator before whitespace, else a plain scalar.
    pending,
    plain,
    /// A plain scalar followed by blanks: a `#` now starts a comment.
    plain_ws,
    /// A plain scalar followed by `:`: blanks now make it a key.
    plain_colon,
    dq,
    /// After a `\` inside a double-quoted scalar.
    dq_esc,
    sq,
    /// After a `'` inside a single-quoted scalar: `''` or the close.
    sq_quote,
    comment,
    /// A `%` directive line.
    directive,
    /// An anchor, alias or tag.
    property,
    /// The rest of a `|` or `>` line.
    header,
    /// The leading blanks of a line inside a block scalar.
    lead,
    /// A block scalar content line past its indentation.
    text,
};

const refuse_after_close = "a value cannot directly follow a closing quote in YAML; put it inside the quotes";
const refuse_after_escape = "a value cannot directly follow a `\\` in a YAML double-quoted scalar; remove the backslash";
const refuse_property = "a value cannot be part of a YAML anchor, alias or tag";
const refuse_directive = "a value cannot be part of a YAML directive";
const refuse_header = "a value cannot be part of a YAML block scalar header; put it on a content line";
const refuse_lead = "a value in a YAML block scalar must start at the block's content indentation; indent it";

pub const Tracker = struct {
    mode: Mode = .structural,
    /// Depth of open `[` and `{`.
    flow: u32 = 0,
    /// Token boundaries crossed: every ended token and every structural
    /// byte that starts none. Bytes inside a token never change it.
    breaks: u32 = 0,
    col: u32 = 0,
    /// Only blanks so far on this line (structural).
    line_start: bool = true,
    /// The previous byte was a blank or a line start (structural, header).
    ws_before: bool = true,
    /// Directly after a closed quoted scalar or flow collection.
    glued: bool = false,
    /// Column of the innermost key or `-` entry on this line, or -1.
    owner: i32 = -1,
    /// Column where the last token on this line started, or -1.
    tok_col: i32 = -1,
    pend_char: u8 = 0,
    pend_count: u8 = 0,
    pend_col: u32 = 0,
    /// Block scalar: whether its content indentation is known yet.
    blk_set: bool = false,
    blk_indent: u32 = 0,
    /// Block scalar: indentation of `|`/`>`'s parent node, at least 0.
    blk_base: u32 = 0,
    /// Block scalar: the least indentation an auto-detected line may have.
    blk_min: u32 = 1,
    /// The comment ends a block scalar header.
    hdr_comment: bool = false,

    pub fn init() Tracker {
        return .{};
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        for (bytes) |b| t.step(b);
    }

    /// The encoding at the current position.
    pub fn context(t: *const Tracker) Context {
        return switch (t.mode) {
            .structural => if (t.glued) refuse(refuse_after_close) else .{ .enc = .yaml_plain },
            .pending, .plain, .plain_ws, .plain_colon => .{ .enc = .yaml_plain },
            .dq => .{ .enc = .yaml_dq },
            .dq_esc => refuse(refuse_after_escape),
            .sq => .{ .enc = .yaml_sq },
            .sq_quote => refuse(refuse_after_close),
            .comment => .{ .enc = .raw_line },
            .directive => refuse(refuse_directive),
            .property => refuse(refuse_property),
            .header => refuse(refuse_header),
            .lead => if (!t.blk_set and t.col >= t.blk_min)
                .{ .enc = .yaml_block, .indent = t.col }
            else
                refuse(refuse_lead),
            .text => .{ .enc = .yaml_block, .indent = t.blk_indent },
        };
    }

    /// Whether `b`, the state after a value was fed, is the state `a` had
    /// before it, so the value stayed inside one token of `a`'s context.
    /// Directional: a value may start the token `a` was about to begin (a
    /// plain scalar at a node position or after blanks, the first line of
    /// a block scalar), but must not leave `b` in such a pending state.
    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        if (a.flow != b.flow or a.breaks != b.breaks or a.glued != b.glued) return false;
        if (a.mode == b.mode) return switch (a.mode) {
            .pending => a.pend_char == b.pend_char and a.pend_count == b.pend_count,
            .header => a.blk_set == b.blk_set and a.blk_indent == b.blk_indent,
            .comment => a.hdr_comment == b.hdr_comment and
                (!a.hdr_comment or (a.blk_set == b.blk_set and a.blk_indent == b.blk_indent)),
            .lead => a.blk_set == b.blk_set and a.blk_min == b.blk_min and
                (if (a.blk_set) a.blk_indent == b.blk_indent and a.col == b.col else a.col == b.col),
            .text => a.blk_indent == b.blk_indent,
            else => true,
        };
        if (b.mode == .plain) return switch (a.mode) {
            .structural, .pending, .plain_ws, .plain_colon => true,
            else => false,
        };
        if (a.mode == .lead and b.mode == .text)
            return !a.blk_set and a.col >= a.blk_min and b.blk_indent == a.col;
        return false;
    }

    /// Why the text could not be followed to its end, or null.
    pub fn finish(t: *const Tracker) ?[]const u8 {
        return switch (t.mode) {
            .dq, .dq_esc => "an unclosed double-quoted scalar",
            .sq => "an unclosed single-quoted scalar",
            else => if (t.flow > 0) "an unclosed flow collection" else null,
        };
    }

    fn step(t: *Tracker, b: u8) void {
        while (t.process(b)) {}
        if (b == '\n') {
            t.col = 0;
        } else {
            t.col += 1;
            if (b == ' ' and t.mode == .lead and t.blk_set and t.col >= t.blk_indent) t.mode = .text;
        }
    }

    fn endTok(t: *Tracker) void {
        t.breaks +%= 1;
    }

    fn startTok(t: *Tracker, mode: Mode, col: u32) void {
        t.mode = mode;
        t.tok_col = @intCast(col);
        t.line_start = false;
        t.glued = false;
    }

    fn toStructural(t: *Tracker, glued: bool) void {
        t.mode = .structural;
        t.ws_before = false;
        t.glued = glued;
    }

    /// Handles `b` in the current mode; true when `b` must be handled again
    /// in the mode it switched to.
    fn process(t: *Tracker, b: u8) bool {
        switch (t.mode) {
            .structural => t.structural(b),
            .pending => return t.pending(b),
            .plain => switch (b) {
                '\n' => return t.endPlain(),
                ' ', '\t', '\r' => t.mode = .plain_ws,
                ':' => t.mode = .plain_colon,
                else => if (t.flow > 0 and isFlowInd(b)) return t.endPlain(),
            },
            .plain_ws => switch (b) {
                '#' => {
                    t.endTok();
                    t.hdr_comment = false;
                    t.mode = .comment;
                },
                ' ', '\t', '\r' => {},
                '\n' => return t.endPlain(),
                ':' => t.mode = .plain_colon,
                else => {
                    if (t.flow > 0 and isFlowInd(b)) return t.endPlain();
                    t.mode = .plain;
                },
            },
            .plain_colon => {
                if (isBlank(b) or b == '\n' or (t.flow > 0 and isFlowInd(b))) {
                    t.endTok();
                    t.resolveColon();
                    t.toStructural(false);
                    return true;
                }
                if (b != ':') t.mode = .plain;
            },
            .dq => switch (b) {
                '\\' => t.mode = .dq_esc,
                '"' => {
                    t.endTok();
                    t.toStructural(true);
                },
                else => {},
            },
            .dq_esc => t.mode = .dq,
            .sq => if (b == '\'') {
                t.mode = .sq_quote;
            },
            .sq_quote => {
                if (b == '\'') {
                    t.mode = .sq;
                    return false;
                }
                t.endTok();
                t.toStructural(true);
                return true;
            },
            .comment => if (b == '\n') {
                t.endTok();
                if (t.hdr_comment) {
                    t.hdr_comment = false;
                    t.mode = .lead;
                    return false;
                }
                t.mode = .structural;
                return true;
            },
            .directive => if (b == '\n') {
                t.endTok();
                t.mode = .structural;
                return true;
            },
            .property => {
                if (isBlank(b) or b == '\n' or (t.flow > 0 and isFlowInd(b))) {
                    t.endTok();
                    t.toStructural(false);
                    return true;
                }
            },
            .header => switch (b) {
                '\n' => t.mode = .lead,
                ' ', '\t', '\r' => t.ws_before = true,
                '#' => if (t.ws_before) {
                    t.hdr_comment = true;
                    t.mode = .comment;
                },
                '1'...'9' => {
                    t.blk_set = true;
                    t.blk_indent = t.blk_base + (b - '0');
                },
                else => {},
            },
            .lead => switch (b) {
                '\n', ' ', '\r' => {},
                else => {
                    if (!t.blk_set and t.col >= t.blk_min) {
                        t.blk_set = true;
                        t.blk_indent = t.col;
                        t.mode = .text;
                        return false;
                    }
                    t.endTok();
                    t.blk_set = false;
                    t.mode = .structural;
                    t.line_start = true;
                    t.ws_before = true;
                    t.glued = false;
                    t.owner = -1;
                    t.tok_col = -1;
                    return true;
                },
            },
            .text => if (b == '\n') {
                t.mode = .lead;
            },
        }
        return false;
    }

    fn endPlain(t: *Tracker) bool {
        t.endTok();
        t.toStructural(false);
        return true;
    }

    fn resolveColon(t: *Tracker) void {
        if (t.tok_col >= 0) t.owner = t.tok_col;
    }

    fn structural(t: *Tracker, b: u8) void {
        switch (b) {
            '\n' => {
                t.endTok();
                t.line_start = true;
                t.ws_before = true;
                t.glued = false;
                t.owner = -1;
                t.tok_col = -1;
                return;
            },
            ' ', '\t', '\r' => {
                t.endTok();
                t.ws_before = true;
                t.glued = false;
                return;
            },
            else => {},
        }
        const at_line_start = t.line_start;
        t.line_start = false;
        switch (b) {
            '#' => {
                t.hdr_comment = false;
                t.mode = .comment;
                t.glued = false;
            },
            '"' => t.startTok(.dq, t.col),
            '\'' => t.startTok(.sq, t.col),
            '[', '{' => {
                t.endTok();
                t.flow += 1;
                t.toStructural(false);
            },
            ']', '}' => {
                t.endTok();
                if (t.flow > 0) t.flow -= 1;
                t.toStructural(true);
            },
            ',' => if (t.flow > 0) {
                t.endTok();
                t.toStructural(false);
            } else t.startTok(.plain, t.col),
            '|', '>' => if (t.flow == 0) {
                t.mode = .header;
                t.glued = false;
                t.ws_before = false;
                t.blk_set = false;
                t.blk_base = if (t.owner > 0) @intCast(t.owner) else 0;
                t.blk_min = if (t.owner >= 0) @as(u32, @intCast(t.owner)) + 1 else 1;
                t.hdr_comment = false;
            } else t.startTok(.plain, t.col),
            '&', '!', '*' => t.startTok(.property, t.col),
            '%' => if (at_line_start and t.col == 0) {
                t.mode = .directive;
            } else t.startTok(.plain, t.col),
            ':' => if (t.glued) {
                t.endTok();
                t.resolveColon();
                t.toStructural(false);
            } else t.startPending(b),
            '-', '?' => t.startPending(b),
            '.' => if (at_line_start and t.col == 0) t.startPending(b) else t.startTok(.plain, t.col),
            else => t.startTok(.plain, t.col),
        }
    }

    fn startPending(t: *Tracker, b: u8) void {
        t.mode = .pending;
        t.pend_char = b;
        t.pend_count = 1;
        t.pend_col = t.col;
        t.glued = false;
    }

    fn pending(t: *Tracker, b: u8) bool {
        const c = t.pend_char;
        if ((c == '-' or c == '.') and b == c and t.pend_col == 0 and t.pend_count < 3) {
            t.pend_count += 1;
            return false;
        }
        const ends = isBlank(b) or b == '\n' or (c == ':' and t.flow > 0 and isFlowInd(b));
        if (ends and t.pend_count == 1 and c != '.') {
            t.endTok();
            switch (c) {
                ':' => t.resolveColon(),
                else => t.owner = @intCast(t.pend_col),
            }
            t.toStructural(false);
            return true;
        }
        if (ends and t.pend_count == 3) {
            t.endTok();
            t.owner = -1;
            t.tok_col = -1;
            t.toStructural(false);
            return true;
        }
        t.startTok(.plain, t.pend_col);
        return true;
    }
};

fn refuse(why: []const u8) Context {
    return .{ .enc = .raw, .refuse = why };
}

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn isFlowInd(b: u8) bool {
    return switch (b) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

// Tests

const testing = std.testing;

fn after(text: []const u8) Tracker {
    var t = Tracker.init();
    t.feed(text);
    return t;
}

fn ctxOf(text: []const u8) Context {
    const t = after(text);
    return t.context();
}

fn encOf(text: []const u8) types.Encoding {
    return ctxOf(text).enc;
}

/// Whether feeding `value` after `prefix` leaves the state as it was.
fn keeps(prefix: []const u8, value: []const u8) bool {
    var t = after(prefix);
    const before = t;
    t.feed(value);
    return Tracker.same(&before, &t);
}

fn expectRefused(text: []const u8) !void {
    try testing.expect(ctxOf(text).refuse != null);
}

test "plain value and key positions" {
    try testing.expectEqual(types.Encoding.yaml_plain, encOf(""));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: abc"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: hello "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("a: 1\n"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("a:\n  "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("- "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: -"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("url: http:"));
    try testing.expect(ctxOf("key: ").refuse == null);
}

test "plain value stays one plain scalar" {
    try testing.expect(keeps("key: ", "hello"));
    try testing.expect(keeps("key: abc", "def"));
    try testing.expect(keeps("key: hello ", "world"));
    try testing.expect(keeps("key: a:", "b"));
    try testing.expect(keeps("key: -", "5"));
    try testing.expect(keeps("", "key"));
    try testing.expect(keeps("key: ", "a#b"));
    try testing.expect(keeps("key: ", "a:b"));
    try testing.expect(keeps("key: ", ""));
    try testing.expect(!keeps("key: ", "a: b"));
    try testing.expect(!keeps("key: ", "a #b"));
    try testing.expect(!keeps("key: ", "a\nb"));
    try testing.expect(!keeps("key: ", " a"));
    try testing.expect(!keeps("key: ", "\"a\""));
    try testing.expect(!keeps("key: ", "[a]"));
    try testing.expect(!keeps("key: abc", " "));
    try testing.expect(!keeps("key: abc", ":"));
    try testing.expect(!keeps("key: -", " a"));
    try testing.expect(!keeps("", "k: v"));
}

test "double-quoted scalar" {
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \""));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \"abc"));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \"a\\\"b"));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \"a 'b' # c"));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \"line\n  more "));
    try expectRefused("key: \"a\\");
    try expectRefused("key: \"a\"");
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("\"k\": "));
}

test "a value in a dq scalar keeps the state; a raw quote does not" {
    try testing.expect(keeps("key: \"", "abc"));
    try testing.expect(keeps("key: \"", "a\\\"b\\\\c"));
    try testing.expect(keeps("key: \"x", "it's # not a comment"));
    try testing.expect(!keeps("key: \"", "a\"b"));
    try testing.expect(!keeps("key: \"", "a\\"));
    try testing.expect(!keeps("[\"", "a\", \"b"));
}

test "single-quoted scalar" {
    try testing.expectEqual(types.Encoding.yaml_sq, encOf("key: '"));
    try testing.expectEqual(types.Encoding.yaml_sq, encOf("key: 'it''s"));
    try testing.expectEqual(types.Encoding.yaml_sq, encOf("key: 'a \"b\" \\ # c"));
    try expectRefused("key: 'a'");
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: 'a' "));
    try testing.expect(keeps("key: '", "it''s"));
    try testing.expect(keeps("key: '", "a\\b"));
    try testing.expect(!keeps("key: '", "it's"));
    try testing.expect(!keeps("key: '", "a'"));
}

test "comments" {
    try testing.expectEqual(types.Encoding.raw_line, encOf("# "));
    try testing.expectEqual(types.Encoding.raw_line, encOf("key: v # "));
    try testing.expectEqual(types.Encoding.raw_line, encOf("key: \"v\" # note"));
    try testing.expectEqual(types.Encoding.raw_line, encOf("  # indented"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: a#b"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("# c\nkey: "));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: \"# "));
    try testing.expectEqual(types.Encoding.yaml_sq, encOf("key: ' #"));
    try testing.expect(keeps("# ", "anything \" ' # here"));
    try testing.expect(!keeps("# ", "a\nb"));
}

test "block scalar with auto-detected indentation" {
    try expectRefused("key: |");
    try expectRefused("key: |-");
    try expectRefused("key: |\n");
    try expectRefused("a:\n  key: |\n  ");
    const first = ctxOf("key: |\n  ");
    try testing.expectEqual(types.Encoding.yaml_block, first.enc);
    try testing.expectEqual(@as(u32, 2), first.indent);
    const later = ctxOf("key: |\n    one\n    two ");
    try testing.expectEqual(types.Encoding.yaml_block, later.enc);
    try testing.expectEqual(@as(u32, 4), later.indent);
    const next = ctxOf("key: >\n   one\n\n   ");
    try testing.expectEqual(types.Encoding.yaml_block, next.enc);
    try testing.expectEqual(@as(u32, 3), next.indent);
    try testing.expectEqual(types.Encoding.yaml_block, encOf("key: |\n  a \" ' # b"));
    try expectRefused("key: |\n    one\n  ");
}

test "block scalar with an indentation indicator" {
    const c = ctxOf("key: |2\n  ");
    try testing.expectEqual(types.Encoding.yaml_block, c.enc);
    try testing.expectEqual(@as(u32, 2), c.indent);
    const kept = ctxOf("key: |2-\n    deeper");
    try testing.expectEqual(@as(u32, 2), kept.indent);
    try expectRefused("key: >+1\n");
    const nested = ctxOf("outer:\n  inner: |1\n   ");
    try testing.expectEqual(types.Encoding.yaml_block, nested.enc);
    try testing.expectEqual(@as(u32, 3), nested.indent);
    const entry = ctxOf("- key: |2\n    ");
    try testing.expectEqual(@as(u32, 4), entry.indent);
    const seq = ctxOf("list:\n  - |1\n   x");
    try testing.expectEqual(@as(u32, 3), seq.indent);
    const comment = ctxOf("key: |2 # note\n  ");
    try testing.expectEqual(types.Encoding.yaml_block, comment.enc);
    try testing.expectEqual(@as(u32, 2), comment.indent);
}

test "block scalar ends at a less indented line" {
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: |\n  text\nnext: "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("a:\n  key: |\n    text\n  next: "));
    try testing.expectEqual(types.Encoding.raw_line, encOf("key: |\n  text\n# "));
    try testing.expectEqual(types.Encoding.yaml_block, encOf("key: |\n  text\n\n  "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: |\nnext: "));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: |2\n  a\nb: \""));
}

test "a value in a block scalar keeps the state" {
    try testing.expect(keeps("key: |\n  ", "line1\n  line2"));
    try testing.expect(keeps("key: |\n  a\n  ", "x\n\n  y"));
    try testing.expect(keeps("key: |2\n  ", "x \" # y"));
    try testing.expect(!keeps("key: |\n  ", "a\nb: c"));
    try testing.expect(!keeps("key: |\n  ", "  a"));
    try testing.expect(!keeps("key: |\n  a\n  ", "x\n"));
    try testing.expect(!keeps("key: |\n  a\n  ", "x\n    y\nz"));
}

test "flow collections" {
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: ["));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: [a, "));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("{a: [b, c"));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("{a: \""));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: [a, b]\nnext: "));
    try expectRefused("key: [a]");
    try testing.expect(keeps("{a: [b, ", "c"));
    try testing.expect(keeps("key: [a, ", "b:c"));
    try testing.expect(!keeps("{a: [b, ", "c, d"));
    try testing.expect(!keeps("{a: [b, ", "c]"));
    try testing.expect(!keeps("{a: [b, ", "c}"));
    try testing.expect(!keeps("{a: ", "[b"));
    try testing.expect(!keeps("{", "a: b"));
    try testing.expect(keeps("key: ", "a]b"));
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("{\"a\":"));
    try testing.expectEqual(types.Encoding.raw_line, encOf("[a, # "));
}

test "properties, directives and document markers" {
    try expectRefused("key: &");
    try expectRefused("key: &anchor");
    try expectRefused("key: !!str");
    try expectRefused("key: *ref");
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("key: &a "));
    try testing.expectEqual(types.Encoding.yaml_dq, encOf("key: !!str \""));
    const blk = ctxOf("key: &a |\n  ");
    try testing.expectEqual(types.Encoding.yaml_block, blk.enc);
    try testing.expectEqual(@as(u32, 2), blk.indent);
    try expectRefused("%YAML 1.2");
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("%YAML 1.2\n---\nkey: "));
    const doc = ctxOf("--- |\n ");
    try testing.expectEqual(types.Encoding.yaml_block, doc.enc);
    try testing.expectEqual(@as(u32, 1), doc.indent);
    try testing.expectEqual(types.Encoding.yaml_plain, encOf("...\n"));
    try testing.expect(keeps("key: ---", "x"));
}

test "finish" {
    try testing.expectEqual(@as(?[]const u8, null), after("a: \"b\"\nc: 'd'\ne: |\n  f\n").finish());
    try testing.expect(after("a: \"b").finish() != null);
    try testing.expect(after("a: \"b\\").finish() != null);
    try testing.expect(after("a: 'b").finish() != null);
    try testing.expect(after("a: 'it'''").finish() == null);
    try testing.expect(after("a: 'it''s").finish() != null);
    try testing.expect(after("a: [b").finish() != null);
    try testing.expect(after("a: \"x # y\n  z\"").finish() == null);
}

test "the tracker is a value type" {
    var a = after("key: \"");
    const b = a;
    a.feed("x\"");
    try testing.expectEqual(types.Encoding.yaml_dq, b.context().enc);
    try testing.expect(a.context().refuse != null);
}
