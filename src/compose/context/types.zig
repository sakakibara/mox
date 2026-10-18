//! The encodings and contexts every format tracker shares.

/// How a value is written where a capture sits.
pub const Encoding = enum {
    /// The value's bytes as they are.
    raw,
    /// The value's bytes, refused when they hold a newline.
    raw_line,
    /// Whole lines (a `# mox: secret` directive's value).
    lines,
    toml_basic,
    toml_ml_basic,
    toml_literal,
    toml_ml_literal,
    toml_bare,
    toml_bare_key,
    yaml_dq,
    yaml_sq,
    yaml_plain,
    yaml_typed,
    yaml_block,
    ini_quoted,
    ini_unquoted,
    ini_section,
    gitconfig_quoted,
    gitconfig_unquoted,
    gitconfig_subsection,
    sh_dq,
    sh_sq,
    sh_word,
    sh_heredoc,
    sh_heredoc_quoted,
    fish_dq,
    fish_sq,
    fish_word,
    ps_dq,
    ps_sq,
    ps_here_dq,
    ps_here_sq,
};

/// What a tracker says about the position of a capture.
pub const Context = struct {
    enc: Encoding,
    /// `yaml_block`: the indentation of the block's continuation lines.
    indent: u32 = 0,
    /// Heredocs and PowerShell here-strings: the terminator line, and
    /// whether `<<-` strips leading tabs before comparing a line with it.
    terminator: []const u8 = "",
    strip_tabs: bool = false,
    /// Set when the position allows no capture at all (inside `${...}`,
    /// `$(...)` or arithmetic, right after an unbraced `$NAME`, an unquoted
    /// PowerShell word, ...): why, with the remedy, as compose prints it.
    refuse: ?[]const u8 = null,
};
