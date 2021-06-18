const std = @import("std");
const data = @import("data.zig");
const unicode = @import("unicode.zig");

/// A source provides content to be parsed. This is usually a source file.
pub const Source = struct {
  /// the content of the source that is to be parsed
  content: []const u8,
  /// offsets if the source is part of a larger file.
  /// these will be added to line/column reporting.
  offsets: struct {
    line: u8,
    column: u8
  },
  /// the name that is to be used for reporting errors.
  /// usually the path of the file.
  name: []const u8,
  /// the absolute locator that identifies this source.
  locator: []const u8,
  /// the locator minus its final element, used for resolving
  /// relative locators inside this source.
  locator_ctx: []const u8,

  /// Walks a source and returns Unicode code points.
  pub const Walker = struct {
    /// The source.
    source: *Source,
    /// Next character to be read.
    cur: [*]const u8,
    /// Cursor position before recently returned code point.
    before: data.Cursor,
    /// length of the recently returned character (1-4)
    recent_length: u3,
    /// Cursor position that has been marked for backtracking.
    marked: data.Cursor,

    /// Initializes a walker to walk the given source, starting at the beginning
    pub fn init(s: *Source) Walker {
      return .{
        .source = s,
        .cur = s.content.ptr,
        .before = .{.at_line = s.offsets.line + 1,
                    .before_column = s.offsets.column, .byte_offset = 0},
        .recent_length = 0,
        .marked = undefined
      };
    }

    fn next(w: *Walker) !u21 {
      w.before.byte_offset += w.recent_length;
      const len = try std.unicode.utf8ByteSequenceLength(w.cur[0]);
      w.recent_length += len;
      switch (len) {
        1 => {
          return @intCast(u21, w.cur[0]);
        },
        2 => {
          return std.unicode.utf8Decode2(w.cur[0..1]);
        },
        3 => {
          return std.unicode.utf8Decode3(w.cur[0..2]);
        },
        4 => {
          return std.unicode.utf8Decode4(w.cur[0..3]);
        },
        else => unreachable
      }
    }

    /// Call this for the first character or whenever the recent character has
    /// not been CR or LF.
    pub fn nextInline(w: *Walker) !u21 {
      w.before.before_column += 1;
      return w.next();
    }

    /// Return true iff the next character will be CR or LF.
    pub fn peek_line_end(w: *Walker) bool {
      return w.cur.* == '\r' or w.cur.* == '\n';
    }

    /// Call this if the recent character was LF.
    pub fn nextAfterLF(w: *Walker) !u21 {
      w.before.before_column = 1;
      w.before.at_line += 1;
      return w.next();
    }

    /// Call this if the recent character was CR.
    pub fn nextAfterCR(w: *Walker) !u21 {
      w.before.before_column = 1;
      w.before.at_line += 1;
      const c = try w.next();
      if (c == '\n') {
        return w.next();
      } else return c;
    }

    /// Marks the current position so that you can backtrack.
    pub fn mark(w: *Walker) void {
      w.marked = w.before;
    }

    /// Backtracks to the recently marked position.
    /// Behavior undefined if mark() has not been called before.
    pub fn resetToMark(w: *Walker) void {
      w.before = w.marked;
      w.cur = &(w.source.content[0]) + w.before.byte_offset;
      w.cur += std.unicode.utf8ByteSequenceLength(w.cur.*) orelse unreachable;
    }

    pub fn contentFrom(w: *Walker, start: u32) []const u8 {
      const len = w.before.byte_offset - start;
      return (w.cur - len)[0..len];
    }
  };
};

pub const LexerContext = struct {
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer only uses this to check whether a character is a command
  /// character; the namespace mapping is only relevant for the interpreter.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u16),
  /// Allocator to be used by the lexer and for the command_characters.
  allocator: *std.mem.Allocator,
};

pub const Lexer = struct {
  pub const Token = enum(u16) {
    /// A comment. Ends either before or after a linebreak depending on whether
    /// it's a comment-break or comment-nonbreak [7.5.1]
    comment,
    /// Indentation whitespace (indent-capture, indent) [7.5.2]
    indent,
    /// Non-significant [7.5.2] or significant (sig-ws) [7.5.3] whitespace.
    /// The lexer is unable to distinguish these in all contexts; however it
    /// will only return line breaks as space in contexts where it cannot be
    /// significant.
    space,
    /// possibly significant linebreak (sig-br) [7.5.3]
    /// also used for non-significant line breaks in trailing empty lines of a
    /// block or argument – parser will dump those.
    ws_break,
    /// Paragraph separator (sig-parsep) [7.5.3]
    parsep,
    /// Escape sequence (escaped-br [7.5.3], escape [7.5.4])
    escape,
    /// Literal text (literal) [7.5.4]
    literal,
    /// ':,' that closes currently open command [7.6]
    closer,
    /// command character inside block config [7.11]
    ns_sym,
    /// symbol reference [7.6.1] started with a command character.
    /// will never be '\end' since that is covered by block_end_open.
    symref,
    /// text identifying a symbol or command name [7.6.1]
    identifier,
    /// '::' introducing accessor and containing identifier [7.6.2]
    access,
    /// Assignment start ':=', must be followed by arglist or block [7.6.4]
    assign,
    /// '(' that is starting a list of arguments [7.9]
    list_start,
    /// ')' that is closing a list of arguments [7.9]
    list_end,
    /// ',' separating list arguments [7.9]
    comma,
    /// '=' or ':=' separating argument name from value [7.9]
    name_sep,
    /// '=' introducing id-setter [7.9]
    id_set,
    /// ':' after identifier or arglist starting a block list [7.10]
    /// also used after block config to start swallow.
    blocks_sep,
    /// ':=' starting, or ':' starting or ending, a block name [7.10]
    block_name_sep,
    /// '\end(' (with \ being the appropriate command character) [7.10]
    /// must be followed up by space, identifier, and list_end
    block_end_open,
    /// name inside '\end('. This token implies that the given name is the
    /// expected one. Either call_id, wrong_call_id or skipping_call_id will
    /// occur inside of '\end(' but the occurring token may have zero length if
    /// the '\end(' does not contain a name.
    /// The token will also include all whitespace inside `\end(…)`.
    ///
    call_id,
    /// decimal digits specifying the swallow depth [7.10]
    swallow_depth,
    /// '<' when introducing block configuration
    diamond_open,
    /// '>' specifying swallowing [7.10] or closing block config [7.11]
    diamond_close,
    /// any special character inside a block with special syntax [7.12]
    special,
    /// signals the end of the current source.
    end_source,

    // -----------
    // following here are error tokens

    /// single code point that is not allowed in Nyarna source
    illegal_code_point,
    /// '(' inside an arglist when not part of a sub-command structure
    illegal_opening_parenthesis,
    /// command character inside a block name or id_setter
    illegal_command_char,
    /// indentation which contains both tab and space characters
    mixed_indentation,
    /// indentation which contains a different indentation character
    /// (tab or space) than what the current block specified to use.
    illegal_indentation,
    /// content behind a ':' ending a block name or starting a block list
    illegal_content_after_colon,
    /// content behind an identifier of an id_setter or block name
    illegal_content_after_id,
    /// '\end' without opening parenthesis following
    invalid_end_command,
    /// '\end(' with \ being the wrong command character
    wrong_ns_end_command,
    /// identifier inside '\end(' with unmatchable name.
    /// will be yielded for length 0 if identifier is missing but non-empty
    /// name is expected.
    wrong_end_subject,
    /// all subsequent values are skipping_end_subject.
    /// skipping_end_subject is a 0 length token that signals that a number
    /// of '\end(…)' constructs is missing in front of a valid '\end(…)'.
    /// The token is emitted before the subject inside of that '\end(…)'.
    /// the distance to skipping_end_subject - 1 is how many were skipped.
    skipping_end_suject,
    _,

    pub fn isError(t: Token) bool {
      return @enumToInt(t) >= @enumToInt(Token.illegal_code_point);
    }

    pub fn numSkippedEnds(t: Token) u32 {
      return @enumToInt(t) - @enumToInt(Token.skipping_end_suject) + 1;
    }
  };

  const State = enum {
    /// initial state and state at the beginning of a block.
    /// may yields space and comment,
    /// will transition to check_indent when non-empty line is encountered.
    indent_capture,
    /// used after linebreak inside block. Searches for empty lines and if any
    /// exist, yields parsep. transitions to check_indent afterwards.
    /// if there is an '\end' after the empty lines, will yield space instead
    /// of parsep.
    check_parsep,
    /// yields indent if any exists, then transitions to check_block_name.
    check_indent,
    /// yields block_name_sep if exists and transitions to read_block_name then,
    /// else transitions to in_block.
    check_block_name,
    /// yields space if exists, yields identifier and transitions to
    /// after_block name or optionally yields block_name_sep and transitions to
    /// in_block.
    read_block_name,
    /// may yield illegal_content_after_id and space.
    /// optionally yields block_name_sep and transitions to in_block.
    after_block_name,
    /// reads content of a block, can start commands. Whitespace is emitted as
    /// sig_space, transitions to check_parsep when encountering a line end.
    in_block,
    /// Expects an identifier. used after '::'.
    after_access_colons,
    /// After a symref or an access. Checks for args or blocks start.
    /// If found, pushes a level with the recent identifier as ID.
    /// Also used after '\end(…)' which employs the same mechanic; the recent
    /// identifier is empty in that case.
    after_id,
    /// yields any encountered space and comments.
    /// optionally yield id_set, then transitions to in_arg.
    arg_start,
    /// used in id setter. may yield space.
    /// yields subject and transitions to after_id. subject may be empty.
    before_id,
    /// may yield illegal_content_after_id and space.
    /// transitions to after_arg.
    after_id,
    /// may yield literal, sig_space. can start commands.
    /// can yield sig-br and transitions to check_nonsig then.
    in_arg,
    /// checks for accessor, explicit end, arglist and blocklist, else
    /// transitions to in_block or in_arg.
    after_args,
    /// may yield illegal_content_after_colon.
    /// can yield diamond_open and transitions to config_item_start then.
    /// can yield diamond_close and transitions to in_block or in_arg then.
    /// can yield swallow_depth and transitions to at_swallow then.
    /// else transitions to indent_capture.
    after_blocks_colon,
    /// like arg_start, but always yields identifier in the end and
    /// transitions to config_item_arg
    config_item_start,
    /// may yield space.
    /// can yield ns_sym, comment which contains only '#' and block_name_sep.
    /// can yield comma and transitions to config_item_start then.
    /// can yield diamond_close and transitions to after_config then.
    config_item_arg,
    /// may yield illegal_content_after_colon.
    /// can yield blocks_sep and transitions to after_blocks_colon then.
    /// else transitions to indent_capture.
    after_config,
    /// like indent_capture, but transitions to special_syntax_check_indent
    special_syntax_indent_capture,
    /// like check_indent, but transitions to special_syntax_check_block_name
    special_syntax_check_indent,
    /// like check_block_name, but transitions to special_syntax
    special_syntax_check_block_name,
    /// emits identifier for text that matches an identifier, sig_space for any
    /// inline whitespace, ws_break for breaks, special for non-identifier
    /// non-whitespace characters (one for each). can start commands.
    special_syntax,
  };

  const Level = struct {
    indentation: u16,
    tabs: ?bool,
    id: []const u8,
    end_char: u21,
  };

  context: *LexerContext,
  cur_stored: (@typeInfo(@TypeOf(Source.Walker.next)).Fn.return_type.?),
  state: State,
  walker: Source.Walker,
  paren_depth: u16,
  colons_disabled_at: ?u15,
  comments_disabled_at: ?u15,

  /// the end of the recently emitted token
  /// (the start equals the end of the previously emitted token)
  recent_end: data.Cursor,
  /// for ns_sym and symref, contains the decoded command character.
  /// for escape, contains the byte length of the escaped code point.
  code_point: u21,

  /// stores the start of the current line.
  /// necessary since searching for empty lines will read over the indentation
  /// of the first non-empty line.
  /// we cache this so we know where the line ended.
  line_start: data.Cursor,
  /// Stores which indentation characters have been seen in recent line.
  indent_char_seen: struct {
    space: bool, tab: bool,
  },
  levels: std.ArrayListUnmanaged(Level),
  level: Level,
  newline_count: u16,

  pub fn init(context: *LexerContext, source: *Source) !Lexer {
    var walker = Source.Walker.init(source);
    return Lexer{
      .context = context,
      .cur_stored = walker.nextInline(),
      .state = .indent_capture,
      .walker = walker,
      .paren_depth = 0,
      .colons_disabled_at = null,
      .comments_disabled_at = null,
      .levels = try std.ArrayListUnmanaged(Level).initCapacity(context.allocator, 32),
      .level = .{
        .indentation = 0,
        .tabs = null,
        .id = undefined,
        .end_char = undefined,
      },
      .newline_count = undefined,
      .recent_end = undefined,
      .line_start = undefined,
      .indent_char_seen = undefined,
      .code_point = undefined,
    };
  }

  /// assumes current character is '#'.
  /// Reads comment content according to [7.5.1].
  /// Returns true iff comment includes newline character.
  inline fn readComment(l: *Lexer, cur: *u21) bool {
    cur.* = l.walker.nextInline() catch |e| {
      l.cur_stored = e;
      return false;
    };
    while (true) {
      switch (cur.*) {
        '#' => while (true) {
          cur.* = l.walker.nextInline() catch |e| {
            l.cur_stored = e;
            return false;
          };
          switch (cur.*) {
            ' ', '\t' => {},
            '\r', '\n' => {
              l.cur_stored = cur.*;
              return false;
            },
            else => break,
          }
        },
        '\r' => {
          l.cur_stored = l.walker.nextAfterCR();
          return true;
        },
        '\n' => {
          l.cur_stored = l.walker.nextAfterLF();
          return true;
        },
        else => cur.* = l.walker.nextInline() catch |e| {
          l.cur_stored = e;
          return false;
        },
      }
    }
  }

  /// starts at cur character. while cur is newline, space or tab,
  /// read next character into cur. return number of newlines seen,
  /// while storing the beginning of the current line into l.line_start.
  inline fn emptyLines(l: *Lexer, cur: *u21) u32 {
    var newlines_seen: u32 = 0;
    while (true) {
      switch (cur.*) {
        '\t' => {
          l.indent_char_seen.tab = true;
        },
        ' '  => {
          l.indent_char_seen.space = true;
        },
        '\r' => {
          newlines_seen += 1;
          l.line_start = l.walker.before;
          l.indent_char_seen = .{.space = false, .tab = false};
          cur.* = l.walker.nextAfterCR() catch |e| {
            l.cur_stored = e;
            return newlines_seen;
          };
          continue;
        },
        '\n' => {
          newlines_seen += 1;
          l.line_start = l.walker.before;
          l.indent_char_seen = .{.space = false, .tab = false};
          cur.* = l.walker.nextAfterLF() catch |e| {
            l.cur_stored = e;
            return newlines_seen;
          };
          continue;
        },
        else => break,
      }
      cur.* = l.walker.nextInline() catch |e| {
        l.cur_stored = e;
        return newlines_seen;
      };
    }
    l.cur_stored = cur.*;
    return newlines_seen;
  }

  pub fn next(l: *Lexer) !Token {
    var cur = try l.cur_stored;
    var seen_text = false;
    var recent_start = l.walker.before;
    while (true) {
      switch (l.state) {
        .indent_capture => {
          if (cur == '#') {
            _ = l.readComment(&cur);
            l.recent_end = l.walker.before;
            return .comment;
          }
          const newlines = l.emptyLines(&cur);
          l.state = .check_indent;
          if (newlines > 0) {
            l.recent_end = l.line_start;
            return .space;
          }
        },
        .check_indent => {
          l.state = if (l.colons_disabled_at == null) .check_block_name else .in_block;
          if (l.recent_end.byte_offset != l.walker.before.byte_offset) {
            l.recent_end = l.walker.before;
            if (l.indent_char_seen.tab and l.indent_char_seen.space) {
              return .mixed_indentation;
            } else if (l.level.tabs) |tabs| {
              if (tabs == l.indent_char_seen.space) {
                return .illegal_indentation;
              } else {
                return .indent;
              }
            } else {
              l.level.tabs = l.indent_char_seen.tab;
              l.level.indentation = @intCast(u16, l.recent_end.byte_offset - l.line_start.byte_offset);
              return .indent;
            }
          }
        },
        .check_block_name => {
          if (cur == ':') {
            l.state = .read_block_name;
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            return .block_name_sep;
          }
          l.state = .in_block;
        },
        .in_block => if (cur == '\r' or cur == '\n') {
          l.state = .check_parsep;
          l.newline_count = 1;
        } else {

        }
      }
    }
  }

  const Surrounding = enum {block, args, config, block_name};
  const ContentResult = struct {hit_line_end: bool, token: ?Token};

  /// return null for an unescaped line end since it may be part of a parsep.
  /// hit_line_end is true if the recently processed character was a line break.
  inline fn processContent(l: *Lexer, comptime ctx: Surrounding, cur: *u21) !ContentResult {
    while (true) {
      switch (cur.*) {
        '\r' => {
          l.cur_stored = l.walker.nextAfterCR();
          l.recent_end = l.walker.before;
          l.newline_count = 1;
          return .{.hit_line_end = true, .token = null};
        },
        '\n' => {
          l.cur_stored = l.walker.nextAfterCR();
          l.recent_end = l.walker.before;
          l.newline_count = 1;
          return .{.hit_line_end = true, .token = null};
        },
        '#' => {
          if (l.comments_disabled_at) {
            l.readLiteral();
            return .{.hit_line_end = false, .token = .literal};
          }
          cur.* = try l.walker.nextInline();
          while (true) {
            switch (cur.*) {
              '#' => while (true) {
                cur.* = try l.walker.nextInline();
                if (cur.* == '\r' or cur.* == '\n') {
                  l.cur_stored = cur.*;
                  l.recent_end = l.walker.before;
                  l.newline_count = 1;
                  return .{.hit_line_end = true, .token = .comment};
                } else if (cur.* != '\t' and cur.* != ' ') break;
              },
              '\r' => {
                l.cur_stored = l.walker.nextAfterCR();
                l.recent_end = l.walker.before;
                l.newline_count = 0;
                return .{.hit_line_end = true, .token = .comment};
              },
              '\n' => {
                l.cur_stored = l.walker.nextAfterLF();
                l.recent_end = l.walker.before;
                l.newline_count = 0;
                return .{.hit_line_end = true, .token = .comment};
              },
              else => cur.* = try l.walker.nextInline()
            }
          }
        },
        't', ' ' => {
          while (true) {
            cur.* = try l.walker.nextInline() catch |e| {
              l.cur_stored = e;
              return .{.hit_line_end = false, .token = .space};
            };
            if (cur.* != '\t' and cur.* != ' ') break;
          }
          if (cur.* != '\r' and cur.* != '\n' and (cur.* != '#' or l.comments_disabled_at != null)) {
            l.cur_stored = cur.*;
            return .{.hit_line_end = false, .token = .sig_space};
          }
          continue;
        },
        0...8, 11...12, 14...31 => {
          return l.advanceAndReturn(.illegal_code_point, null);
        },
        '>' => if (ctx == .config) {
          return l.advanceAndReturn(.diamond_close, .after_config);
        },
        ':' => switch (ctx) {
          .block_name => return l.advanceAndReturn(.block_name_sep, .after_block_name),
          .args => {
            cur.* = l.walker.nextInline() catch |e| {
              l.cur_stored = e;
              return .{.hit_line_end = false, .token = .literal};
            };
            if (cur.* == '=') {
              return l.advanceAndReturn(.name_sep, null);
            }
          }
        },
        ',' => if (ctx == .args or ctx == .config) {
          return l.advanceAndReturn(.comma, null);
        },
        '=' => if (ctx == .args) {
          return l.advanceAndReturn(.name_sep, null);
        },
        '(' => if (ctx == .args) {
          return l.advanceAndReturn(.illegal_opening_parenthesis, null);
        },
        ')' => if (ctx == .args) {
          l.paren_depth -= 1;
          return l.advanceAndReturn(.list_end, .after_args);
        }
      }
      if (ctx == .config) {
        const cat = unicode.category(cur.*);
        if (unicode.MPS.contains(cat)) {
          return l.advanceAndReturn(.ns_sym, null);
        }
      } else {
        if (l.context.command_characters.contains(cur.*)) {
          return l.genCommand(cur);
        } else if (l.checkEndCommand(cur)) {
          return l.genCommand(cur);
        }
      }
      l.readLiteral(cur);
      return .{.hit_line_end = false, .token = .literal};
    }
  }

  inline fn advanceAndReturn(l: *Lexer, value: Token, comptime new_state: ?State) ContentResult {
    l.cur_stored = l.walker.nextInline();
    if (new_state) |state| {
      l.state = state;
    }
    l.recent_end = l.walker.before;
    return .{.hit_line_end = false, .token = value};
  }

  inline fn readLiteral(l: *Lexer, cur: *u21, comptime ctx: Surrounding) void {
    const start = l.walker.before.byte_offset;
    var id_chars = 0;
    while (true) {
      switch (cur.*) {
        0...32 => break,
        '#' => if (!l.comments_disabled_at) break,
        '>' => if (ctx == .config) break,
        ':' => switch(ctx) {
          .block_name => break,
          .args => {
            cur.* = l.walker.nextInline();
            if (cur.* == '=') {
              l.walker.cur -= l.walker.recent_length;
              l.walker.before -= l.walker.recent_length;
              break;
            } else continue;
          }
        },
        ',' => if (ctx == .args or ctx == .config) break,
        '=', '(', ')' => if (ctx == .args) break,
      }
      cur.* = l.walker.nextInline();
    }
  }

  inline fn genCommand(l: *Lexer, cur: *u21) ContentResult {
    const start = l.walker.before.byte_offset;
    l.code_point = cur.*;
    cur.* = l.walker.nextInline();
    var cat = unicode.category(cur.*);
    if (unicode.MPS.contains(cat)) {
      const name_start = l.walker.before.byte_offset;
      while (true) {
        cur.* = unicode.category(cur.*);
        if (!unicode.MPS.contains(unicode.category(cur.*))) break;
      }

      const len = l.walker.before.byte_offset - start;
      if (std.mem.eql(u8, (l.walker.cur - len)[0..len], &"end")) {
        if (cur.* == '(') {
          l.cur_stored = l.walker.nextInline();
          l.state = .before_subject;
          return .{.hit_line_end = false, .token = .block_end_open};
        } else {
          l.cur_stored = cur.*;
          return .{.hit_line_end = false, .token = .invalid_end_command};
        }
      } else {
        l.cur_stored = cur.*;
        l.state = .after_expr;
        return .{.hit_line_end = false, .token = .symref};
      }
    } else switch (cur.*) {
      '\r' => {
        l.cur_stored = l.walker.nextAfterCR();
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        l.code_point = 1;
        return .{.hit_line_end = true, .token = .escape};
      },
      '\n' => {
        l.cur_stored = l.walker.nextAfterLF();
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        l.code_point = 1;
        return .{.hit_line_end = true, .token = .escape};
      },
      '\t', ' ' => {
        cur.* = l.walker.nextInline();
        l.walker.mark();
        while (cur.* == '\t' or cur.* == ' ') {
          cur.* = l.walker.nextInline();
        }
        if (cur.* == '\r') {
          l.cur_stored = l.walker.nextAfterCR();
        } else if (cur.* == '\n') {
          l.cur_stored = l.walker.nextAfterLF();
        } else {
          l.walker.resetToMark();
          l.recent_end = l.walker.before;
          l.code_point = l.recent_end.byte_offset - start;
          return .{.hit_line_end = false, .token = .escape};
        }
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        l.code_point = 1;
        return .{.hit_line_end = true, .token = .escape};
      },
      else => {
        l.cur_stored = l.walker.nextInline();
        l.recent_end = l.walker.before;
        l.code_point = l.recent_end.byte_offset - start;
        return .{.hit_line_end = false, .token = .escape};
      }
    }
  }

  const EndCheckError = error {
    no_end_command
  };

  inline fn checkEndCommand(l: Lexer, cur: *u21) EndCheckError!void {
    l.walker.mark();
    defer l.walker.resetToMark();
    cur.* = l.walker.nextInline();
    if (cur.* != 'e') return .no_end_command;
    cur.* = l.walker.nextInline();
    if (cur.* != 'n') return .no_end_command;
    cur.* = l.walker.nextInline();
    if (cur.* != 'd') return .no_end_command;
    cur.* = l.walker.nextInline();
    if (cur.* != '(') return .no_end_command;
    if (l.matchEndCommand() != .end_subject) return .no_end_command;
    cur.* = l.walker.nextInline();
    if (cur.* != ')') return .no_end_command;
  }

  fn matchEndCommand() Token {
    while (true) {
      var cur = l.walker.nextInline();
      if (cur != '\t' and cur != ' ') break;
    }
    const start = l.walker.before.byte_offset;
    while (unicode.MPS.contains(unicode.category(cur))) {
      cur = l.walker.nextInline();
    }
    const subject = l.walker.contentFrom(start);
    var ret: Token = undefined;
    l.cur_stored = cur;
    if (std.mem.eql(u8, l.level.id, subject)) {
      ret = .end_subject;
    } else {
      ret = .skipping_end_suject;
      var found = false;
      var i = l.levels.items.len - 1;
      while (i <= 0) : (i -= 1) {
        if (std.mem.eql(u8, l.levels.items[i].id, subject)) {
          found = true;
          break;
        }
        ret = ret + 1;
      }
      if (found) {
        return ret;
      } else {
        return .wrong_end_subject;
      }
    }
  }
};

test "empty source" {
  var src = Source{
    .content = "\n",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "empty",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };
  var ctx = LexerContext{
    .command_characters = .{},
    .allocator = std.testing.allocator,
  };
  try ctx.command_characters.put(std.testing.allocator, '\\', 0);
  var l = try Lexer.init(&ctx, &src);
  std.debug.assert((try l.next()) == .end_source);
}