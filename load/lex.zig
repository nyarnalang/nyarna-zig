const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const Interpreter = @import("interpret.zig").Interpreter;

const unicode = @import("unicode.zig");
const Token = model.Token;

const EncodedCharacter = unicode.EncodedCharacter;

/// Walks a source and returns Unicode code points.
pub const Walker = struct {
  /// The source.
  source: *const model.Source,
  /// Next character to be read.
  cur: [*]const u8,
  /// Cursor position before recently returned code point.
  before: model.Cursor,
  /// length of the recently returned character (1-4)
  recent_length: u3,
  /// Cursor position that has been marked for backtracking.
  marked: model.Cursor,

  /// Initializes a walker to walk the given source, starting at the beginning
  pub fn init(s: *const model.Source) Walker {
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
    w.recent_length = std.unicode.utf8ByteSequenceLength(w.cur[0]) catch |e| {
      w.recent_length = 1;
      w.cur += 1;
      return e;
    };
    defer w.cur += w.recent_length;
    switch (w.recent_length) {
      1 => {
        return @intCast(u21, w.cur[0]);
      },
      2 => {
        return std.unicode.utf8Decode2(w.cur[0..2]);
      },
      3 => {
        return std.unicode.utf8Decode3(w.cur[0..3]);
      },
      4 => {
        return std.unicode.utf8Decode4(w.cur[0..4]);
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
    w.cur = w.source.content.ptr + w.before.byte_offset;
    w.recent_length = std.unicode.utf8ByteSequenceLength(w.cur[0])
      catch unreachable;
    w.cur += w.recent_length;
  }

  pub fn contentFrom(w: *Walker, start: usize) []const u8 {
    const len = w.before.byte_offset - start;
    return (w.cur - len - 1)[0..len];
  }

  pub fn lastUtf8Unit(w: *Walker) []const u8 {
    return (w.cur - w.recent_length)[0..w.recent_length];
  }

  pub fn posFrom(w: *Walker, start: model.Cursor) model.Position {
    return .{.source = w.source.meta, .start = start, .end = w.before};
  }
};

pub const Lexer = struct {

  const State = enum(i8) {
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
    /// reads content of a block, can start commands. Whitespace is emitted as
    /// space, transitions to check_parsep when encountering a line end.
    in_block,
    /// may yield space and identifier.
    /// yields either block_name_sep or missing_block_name_sep and transitions
    /// to indent_capture.
    read_block_name,
    /// Expects an identifier. used after '::'.
    after_access_colons,
    /// Expects either args start or blocks start. used after ':='.
    after_assign,
    /// After a symref or an access. Checks for args or blocks start.
    /// If found, pushes a level with the recent identifier as ID.
    /// Also used after '\end(…)' which employs the same mechanic; the recent
    /// identifier is empty in that case.
    after_id,
    /// yields any encountered space and comments.
    /// optionally yield id_set, then transitions to in_arg.
    arg_start,
    /// used in id setter. may yield space.
    /// yields identifier and transitions to in_arg. identifier may be empty.
    before_id_setter,
    /// guarantees to yield call_id, which may be empty.
    /// transitions to after_end_id.
    before_end_id,
    /// may yield list_end and transitions to after_id.
    after_end_id,
    /// may yield literal, space. can start commands.
    /// can yield sig-br and transitions to check_nonsig then.
    in_arg,
    /// checks for accessor, explicit end, arglist and blocklist, else
    /// transitions to in_block or in_arg.
    after_args,
    /// can yield diamond_open and transitions to config_item_start then.
    /// can yield diamond_close and transitions to at_header.
    /// can yield swallow_depth and transitions to at_swallow then.
    /// else transitions to at_header.
    ///
    /// used for instructing the lexer to read a block header in special syntax.
    /// in that case, the state chain from here returns to special_syntax
    /// instead of eventually transitioning to at_header.
    after_blocks_colon,
    /// line behind blocks start, block name or swallow.
    /// may yield space, comment and illegal_content_at_header.
    /// transitions to indent_capture after newline.
    at_header,
    /// like arg_start, but always yields identifier in the end and
    /// transitions to config_item_arg
    config_item_start,
    /// may yield space.
    /// can yield ns_sym, comment which contains only '#' and block_name_sep.
    /// can yield comma and transitions to config_item_start then.
    /// can yield diamond_close and transitions to after_config then.
    config_item_arg,
    /// can yield blocks_sep and transitions to after_blocks_colon then.
    /// else transitions to at_header or special_syntax.
    after_config,
    /// may yield diamond_close (it's an error if it doesn't), then
    /// transitions to at_header or special_syntax.
    after_depth,
    /// like indent_capture, but transitions to special_syntax_check_indent
    special_syntax_indent_capture,
    /// like check_parsep, but transitions to special_syntax_check_indent
    special_syntax_check_parsep,
    /// like check_indent, but transitions to special_syntax_check_block_name
    special_syntax_check_indent,
    /// like check_block_name, but transitions to special_syntax
    special_syntax_check_block_name,
    /// emits identifier for text that matches an identifier, space for any
    /// inline whitespace, ws_break for breaks, special for non-identifier
    /// non-whitespace characters (one for each). can start commands.
    special_syntax,
  };

  const Level = struct {
    indentation: u16,
    tabs: ?bool,
    id: []const u8,
    end_char: u21,
    special: enum{disabled, standard_comments, comments_without_newline},
  };

  const newline = @as([]const u8, "\n");

  intpr: *Interpreter,
  cur_stored: (@typeInfo(@TypeOf(Walker.next)).Fn.return_type.?),
  state: State,
  walker: Walker,
  paren_depth: u16,
  colons_disabled_at: ?usize,
  comments_disabled_at: ?usize,

  /// the end of the recently emitted token
  /// (the start equals the end of the previously emitted token)
  recent_end: model.Cursor,
  /// the recently read id. equals the content for identifier and call_id,
  /// equals the name behind the command character for symref,
  /// equals the character behind the command character for escape.
  recent_id: []const u8,
  /// the recently expected id. set when recent_id is not the expected id, i.e.
  /// when .wrong_end_command or .skipping_end_command is emitted.
  /// used for error reporting.
  recent_expected_id: []const u8,
  /// for ns_sym and symref, contains the decoded command character.
  /// for swallow_depth, contains the parsed depth.
  code_point: u21,
  /// the namespace of the recently read symref.
  ns: u15,

  /// stores the start of the current line.
  /// necessary since searching for empty lines will read over the indentation
  /// of the first non-empty line.
  /// we cache this so we know where the line ended.
  line_start: model.Cursor,
  /// Stores which indentation characters have been seen in recent line.
  indent_char_seen: struct {
    space: bool, tab: bool,
  },
  levels: std.ArrayListUnmanaged(Level),
  level: Level,
  newline_count: u16,

  pub fn init(intpr: *Interpreter) !Lexer {
    var ret = Lexer{
      .intpr = intpr,
      .cur_stored = undefined,
      .state = .indent_capture,
      .walker = Walker.init(intpr.input),
      .paren_depth = 0,
      .colons_disabled_at = null,
      .comments_disabled_at = null,
      .levels =
        try std.ArrayListUnmanaged(Level).initCapacity(
          intpr.allocator(), 32),
      .level = .{
        .indentation = 0,
        .tabs = null,
        .id = undefined,
        .end_char = undefined,
        .special = .disabled,
      },
      .newline_count = 0,
      .recent_end = undefined,
      .recent_id = undefined,
      .recent_expected_id = undefined,
      .line_start = undefined,
      .indent_char_seen = undefined,
      .code_point = undefined,
      .ns = undefined,
    };
    ret.cur_stored = ret.walker.nextInline();
    ret.recent_end = ret.walker.before;
    return ret;
  }

  pub fn deinit(_: *Lexer) void {
    // nothing to do – all allocated data managed by upstream Context.
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
          if (l.level.special == .comments_without_newline) {
            l.cur_stored = cur.*;
            return false;
          } else {
            l.cur_stored = l.walker.nextAfterCR();
            return true;
          }
        },
        '\n' => {
          if (l.level.special == .comments_without_newline) {
            l.cur_stored = cur.*;
            return false;
          } else {
            l.cur_stored = l.walker.nextAfterLF();
            return true;
          }
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
  inline fn emptyLines(l: *Lexer, cur: *u21) u16 {
    var newlines_seen: u16 = 0;
    l.line_start = l.walker.before;
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
          l.indent_char_seen = .{.space = false, .tab = false};
          cur.* = l.walker.nextAfterCR() catch |e| {
            l.cur_stored = e;
            l.line_start = l.walker.before;
            return newlines_seen;
          };
          l.line_start = l.walker.before;
          continue;
        },
        '\n' => {
          newlines_seen += 1;

          l.indent_char_seen = .{.space = false, .tab = false};
          cur.* = l.walker.nextAfterLF() catch |e| {
            l.cur_stored = e;
            l.line_start = l.walker.before;
            return newlines_seen;
          };
          l.line_start = l.walker.before;
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

  /// transition to a new state via the offset between base_from and base_to.
  /// used for transparently handling special_syntax transitions.
  inline fn transition(l: *Lexer, comptime base_from: State, base_to: State)
      void {
    l.state = @intToEnum(State,
      @enumToInt(l.state) + (@enumToInt(base_to) - @enumToInt(base_from)));
  }

  pub fn next(l: *Lexer) !Token {
    var cur = l.cur_stored catch |e| {
      l.cur_stored = l.walker.nextInline();
      return e;
    };
    while (true) {
      switch (l.state) {
        .indent_capture, .special_syntax_indent_capture => {
          switch (cur) {
            4 => {
              return .end_source;
            },
            '#' => {
              if (l.newline_count > 0) {
                l.recent_end = l.walker.before;
                l.newline_count = 0;
                return .space;
              }
              _ = l.readComment(&cur);
              l.recent_end = l.walker.before;
              return .comment;
            },
            else => {
              l.newline_count += l.emptyLines(&cur);
              l.transition(.indent_capture, .check_indent);
              if (l.newline_count > 0) {
                l.recent_end = l.line_start;
                return .space;
              }
            }
          }
        },
        .check_indent, .special_syntax_check_indent => {
          if (cur == 4) {
            return .end_source;
          }
          l.transition(.check_indent,
            if (l.colons_disabled_at == null) State.check_block_name
            else .in_block);
          if (l.recent_end.byte_offset != l.walker.before.byte_offset) {
            l.level.indentation = @intCast(
              u16, l.recent_end.byte_offset - l.line_start.byte_offset);
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
              return .indent;
            }
          }
        },
        .check_parsep, .special_syntax_check_parsep => {
          const newlines = l.emptyLines(&cur);
          l.recent_end = l.line_start;
          l.transition(.check_parsep, .check_indent);
          if (newlines > 0) {
            l.newline_count += newlines;
            return .parsep;
          } else if (l.newline_count > 0) {
            return .ws_break;
          }
        },
        .check_block_name, .special_syntax_check_block_name => {
          if (cur == ':') {
            l.state = .read_block_name;
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            // if previous block disabled comments, re-enable them. this needs
            // not be done for disabled colons, because if colons are disabled,
            // we would never end up here.
            if (l.comments_disabled_at) |depth| {
              if (depth == l.levels.items.len) l.comments_disabled_at = null;
            }
            // if previous block had special syntax, disable it.
            l.level.special = .disabled;
            return .block_name_sep;
          }
          l.transition(.check_block_name, .in_block);
        },
        .in_block, .special_syntax => {
          const res = try
            if (l.state == .in_block) l.processContent(.block, &cur)
            else l.processContent(.special, &cur);

          if (res.hit_line_end) {
            l.transition(.in_block, .check_parsep);
          }
          if (res.token) |t| {
            l.recent_end = l.walker.before;
            return t;
          } else {
            cur = l.cur_stored catch {
              l.recent_end = l.walker.before;
              return .ws_break;
            };
          }
        },
        .in_arg => {
          const res = try l.processContent(.args, &cur);
          l.recent_end = l.walker.before;
          if (res.token) |t| {
            return t;
          } else {
            return .ws_break;
          }
        },
        .arg_start => {
          if (try l.readDumpableSpace(&cur)) {
            l.recent_end = l.walker.before;
            return .space;
          }
          switch (cur) {
            4 => {
              return .end_source;
            },
            '=' => {
              l.cur_stored = l.walker.nextInline();
              l.recent_end = l.walker.before;
              l.state = .before_id_setter;
              return .id_set;
            },
            else => l.state = .in_arg,
          }
        },
        .before_id_setter => {
          if (try l.readDumpableSpace(&cur)) {
            l.recent_end = l.walker.before;
            return .space;
          }
          l.state = .in_arg;
          if (l.readIdentifier(&cur)) {
            // while the call ID must be recognized by the lexer to be able to
            // close the command later, we parse additional (illegal) content
            // normally. The parser will produce appropriate errors.
            l.recent_end = l.walker.before;
            l.level.id = l.recent_id;
            return .call_id;
          } else {
            // no proper ID, therefore level ID is not changed. Just emit the
            // rest of the content normally, parser will report an error.
          }
        },
        .after_access_colons => {
          if (l.readIdentifier(&cur)) {
            l.state = .after_id;
            l.recent_end = l.walker.before;
            return .identifier;
          }
          l.state = l.curBaseState();
        },
        .after_assign => {
          if (try l.exprContinuation(&cur, false)) |t| {
            l.recent_end = l.walker.before;
            return t;
          }
          l.state = l.curBaseState();
          if (l.cur_stored) {} else |e| {
            l.cur_stored = l.walker.nextInline();
            return e;
          }
        },
        .read_block_name => {
          const res = try l.processContent(.block_name, &cur);
          if (res.hit_line_end) {
            std.debug.assert(res.token == null);
            l.newline_count = 1;
            l.state = .indent_capture;
            l.recent_end = l.walker.before;
            return .missing_block_name_sep;
          }
          if (res.token) |t| {
            l.recent_end = l.walker.before;
            return t;
          } else unreachable;
        },
        .after_id => {
          if (try l.exprContinuation(&cur, false)) |t| {
            l.recent_end = l.walker.before;
            return t;
          } else {
            l.state = l.curBaseState();
          }
        },
        .after_args => {
          if (try l.exprContinuation(&cur, true)) |t| {
            l.recent_end = l.walker.before;
            return t;
          } else {
            l.level = l.levels.pop();
            l.state = l.curBaseState();
          }
        },
        .after_blocks_colon => switch (cur) {
          '<' => {
            l.state = .config_item_start;
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            return .diamond_open;
          },
          '>' => {
            l.state = if (l.level.special == .disabled) .at_header
                      else .special_syntax;
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            return .diamond_close;
          },
          '0'...'9' => {
            l.readNumber(&cur);
            l.state = .after_depth;
            return .swallow_depth;
          },
          else => l.state = if (l.level.special == .disabled) .at_header
                            else .special_syntax,
        },
        .at_header => {
          const res = try l.processContent(.block, &cur);
          if (res.hit_line_end) {
            l.newline_count = 1;
            l.state = .indent_capture;
          } else {
            // ignore proposed state changes, e.g. from encountering a command.
            // anything that would cause a state change is illegal content here.
            l.state = .at_header;
          }
          l.recent_end = l.walker.before;
          if (res.token) |t| {
            return switch (t) {
              .space, .ws_break => .space,
              .comment => .comment,
              else => .illegal_content_at_header
            };
          } else {
            cur = l.cur_stored catch {
              return .space;
            };
          }
        },
        .config_item_start => {
          if (try l.readDumpableSpace(&cur)) {
            l.recent_end = l.walker.before;
            return .space;
          }
          if (cur == '>') {
            l.cur_stored = l.walker.nextInline();
            l.state = .after_config;
            return .diamond_close;
          }
          if (!l.readIdentifier(&cur)) {
            // we always emit .identifier here, even if it has 0 length.
            // if reading an identifier fails, we need to store cur manually
            // while this is done automatically on success.
            l.cur_stored = cur;
          }
          l.state = .config_item_arg;
          l.recent_end = l.walker.before;
          return .identifier;
        },
        .config_item_arg => {
          const res = try l.processContent(.config, &cur);
          l.recent_end = l.walker.before;
          if (res.token) |t| {
            return t;
          } else {
            cur = l.cur_stored catch {
              return .space;
            };
          }
        },
        .after_config => {
          if (cur == ':') {
            l.state = .after_blocks_colon;
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            return .blocks_sep;
          } else {
            l.state = if (l.level.special == .disabled) .at_header
                      else .special_syntax;
          }
        },
        .after_depth => {
          l.state = if (l.level.special == .disabled) .at_header
                    else .special_syntax;
          if (cur == '>') {
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            return .diamond_close;
          }
        },
        .before_end_id => {
          var res = l.matchEndCommand(true);
          if (res == .call_id) {
            l.level = l.levels.pop();
          } else {
            l.recent_expected_id = l.level.id;
            var i = @enumToInt(res) + 1;
            while (i > @enumToInt(Token.skipping_call_id)) : (i = i - 1) {
              l.level = l.levels.pop();
            }
          }
          if (l.comments_disabled_at) |depth| {
            if (l.levels.items.len < depth) {
              l.comments_disabled_at = null;
            }
          }
          if (l.colons_disabled_at) |depth| {
            if (l.levels.items.len < depth) {
              l.colons_disabled_at = null;
            }
          }
          l.state = .after_end_id;
          l.recent_end = l.walker.before;
          return res;
        },
        .after_end_id => {
          if (cur == ')') {
            l.cur_stored = l.walker.nextInline();
            l.recent_end = l.walker.before;
            l.state = .after_id;
            l.recent_id = "";
            return .list_end;
          } else {
            // this will be recognized as error by the parser.
            l.state = .in_block;
          }
        },
      }
    }
  }

  const Surrounding = enum {block, args, config, block_name, special};
  const ContentResult = struct {
    hit_line_end: bool = false,
    token: ?Token = null
  };

  /// return null for an unescaped line end since it may be part of a parsep.
  /// hit_line_end is true if the recently processed character was a line break.
  inline fn processContent(l: *Lexer, comptime ctx: Surrounding, cur: *u21)
      !ContentResult {
    switch (cur.*) {
      4 => {
        return ContentResult{.token = .end_source};
      },
      '\r' => {
        l.cur_stored = l.walker.nextAfterCR();
        l.newline_count = 1;
        return ContentResult{.hit_line_end = true};
      },
      '\n' => {
        l.cur_stored = l.walker.nextAfterLF();
        l.newline_count = 1;
        return ContentResult{.hit_line_end = true};
      },
      '#' => {
        switch (ctx) {
          .block_name => {
            l.cur_stored = l.walker.nextInline();
            return ContentResult{.token = .illegal_character_for_id};
          },
          .config => {
            l.cur_stored = l.walker.nextInline();
            return ContentResult{.token = .comment};
          },
          .special => {
            if (l.comments_disabled_at != null) {
              l.code_point =  cur.*;
              l.cur_stored = l.walker.nextInline();
              return ContentResult{.token = .special};
            } else {
              const line_end = l.readComment(cur);
              l.newline_count = 0;
              return ContentResult{.hit_line_end = line_end, .token = .comment};
            }
          },
          else => {
            if (l.comments_disabled_at != null) {
              l.readLiteral(cur, ctx);
              return ContentResult{.token = .literal};
            } else {
              const line_end = l.readComment(cur);
              l.newline_count = 0;
              return ContentResult{.hit_line_end = line_end, .token = .comment};
            }
          }
        }
      },
      '\t', ' ' => {
        while (true) {
          cur.* = l.walker.nextInline() catch |e| {
            l.cur_stored = e;
            return ContentResult{.token = .space};
          };
          if (cur.* != '\t' and cur.* != ' ') break;
        }
        l.cur_stored = cur.*;
        return ContentResult{.token = .space};
      },
      0...3, 5...8, 11...12, 14...31 => {
        return l.advanceAndReturn(.illegal_code_point, null);
      },
      '>' => if (ctx == .config) {
        return l.advanceAndReturn(.diamond_close, .after_config);
      },
      ':' => switch (ctx) {
        .block_name =>
          return l.advanceAndReturn(.block_name_sep, .after_blocks_colon),
        .args => {
          cur.* = l.walker.nextInline() catch |e| {
            l.cur_stored = e;
            return ContentResult{.token = .literal};
          };
          if (cur.* == '=') {
            return l.advanceAndReturn(.name_sep, null);
          }
        },
        .config => {
          l.cur_stored = l.walker.nextInline();
          return ContentResult{.token = .block_name_sep};
        },
        else => {},
      },
      ',' => if (ctx == .args or ctx == .config) {
        return l.advanceAndReturn(.comma,
            if (ctx == .config) .config_item_start else .arg_start);
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
      },
      else => {}
    }
    if (ctx == .config) {
      const cat = unicode.category(cur.*);
      if (unicode.MPS.contains(cat)) {
        l.code_point = cur.*;
        return l.advanceAndReturn(.ns_sym, null);
      }
    } else {
      if (l.intpr.command_characters.get(cur.*)) |ns| {
        l.ns = ns;
        return l.genCommand(cur);
      } else if (cur.* == l.level.end_char and l.checkEndCommand()) {
        return l.genCommand(cur);
      }
    }
    return ContentResult{.token =
      switch(ctx) {
        .block_name => blk: {
          if (l.readIdentifier(cur)) break :blk .identifier;
          while (true) {
            cur.* = l.walker.nextInline() catch |e| {
              l.cur_stored = e;
              l.recent_end = l.walker.before;
              break :blk Token.illegal_characters;
            };
            switch (cur.*) {
              4, ' ', '\t', '\r', '\n', ':' => break,
              else => {
                if (l.intpr.command_characters.get(cur.*) != null or
                    unicode.L.contains(unicode.category(cur.*))) break;
              }
            }
          }
          break :blk Token.illegal_characters;
        },
        .special => blk: {
          if (l.readIdentifier(cur)) break :blk .identifier;
          l.code_point = cur.*;
          l.cur_stored = l.walker.nextInline();
          break :blk Token.special;
        },
        else => blk: {
          l.readLiteral(cur, ctx);
          break :blk .literal;
        },
      }
    };
  }

  inline fn advanceAndReturn(l: *Lexer, value: Token,
                             comptime new_state: ?State) ContentResult {
    l.cur_stored = l.walker.nextInline();
    if (new_state) |state| {
      l.state = state;
    }
    return .{.token = value};
  }

  inline fn readLiteral(l: *Lexer, cur: *u21, comptime ctx: Surrounding) void {
    while (true) {
      switch (cur.*) {
        0...32 => break,
        '#' => if (l.comments_disabled_at == null) break,
        '>' => if (ctx == .config) break,
        ':' => switch(ctx) {
          .block_name => break,
          .args => {
            l.walker.mark();
            cur.* = l.walker.nextInline() catch |e| {
              l.cur_stored = e;
              return;
            };
            if (cur.* == '=') {
              l.walker.resetToMark();
              cur.* = ':';
              break;
            } else continue;
          },
          else => {},
        },
        ',' => if (ctx == .args or ctx == .config) break,
        '=', '(', ')' => if (ctx == .args) break,
        else => if (l.intpr.command_characters.contains(cur.*)) break,
      }
      cur.* = l.walker.nextInline() catch |e| {
        l.cur_stored = e;
        return;
      };
    }
    l.cur_stored = cur.*;
  }

  inline fn genCommand(l: *Lexer, cur: *u21) ContentResult {
    l.code_point = cur.*;
    cur.* = l.walker.nextInline() catch |e| {
      l.cur_stored = e;
      return .{.token = .illegal_command_char};
    };
    if (l.readIdentifier(cur)) {
      if (std.mem.eql(u8, l.recent_id, "end")) {
        if (cur.* == '(') {
          l.cur_stored = l.walker.nextInline();
          l.state = .before_end_id;
          return .{.token = .block_end_open};
        } else {
          return .{.token = .invalid_end_command};
        }
      } else {
        l.state = .after_id;
        l.cur_stored = cur.*;
        return .{.token = .symref};
      }
    } else switch (cur.*) {
      '\r' => {
        l.cur_stored = l.walker.nextAfterCR();
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        l.recent_id = newline;
        return .{.hit_line_end = true, .token = .escape};
      },
      '\n' => {
        l.cur_stored = l.walker.nextAfterLF();
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        l.recent_id = newline;
        return .{.hit_line_end = true, .token = .escape};
      },
      '\t', ' ' => {
        l.recent_id = l.walker.lastUtf8Unit();
        cur.* = l.walker.nextInline() catch |e| {
          l.cur_stored = e;
          l.recent_end = l.walker.before;
          return .{.token = .escape};
        };
        l.walker.mark();
        while (cur.* == '\t' or cur.* == ' ') {
          cur.* = l.walker.nextInline() catch {
            break;
          };
        }
        if (cur.* == '\r') {
          l.cur_stored = l.walker.nextAfterCR();
          l.recent_id = newline;
        } else if (cur.* == '\n') {
          l.cur_stored = l.walker.nextAfterLF();
          l.recent_id = newline;
        } else {
          l.walker.resetToMark();
          l.cur_stored = l.walker.nextInline();
          l.recent_end = l.walker.before;
          return .{.token = .escape};
        }
        l.recent_end = l.walker.before;
        l.newline_count = 0;
        return .{.hit_line_end = true, .token = .escape};
      },
      else => {
        l.recent_id = l.walker.lastUtf8Unit();
        l.cur_stored = l.walker.nextInline();
        l.recent_end = l.walker.before;
        return .{.token = .escape};
      }
    }
  }

  fn readIdentifier(l: *Lexer, cur: *u21) bool {
    const name_start = l.walker.before.byte_offset;
    while (unicode.L.contains(unicode.category(cur.*))) {
      cur.* = l.walker.nextInline() catch |e| {
        l.cur_stored = e;
        const len = l.walker.before.byte_offset - name_start;
        l.recent_id = (l.walker.cur - len)[0..len];
        return true;
      };
    }
    l.recent_id = l.walker.contentFrom(name_start);
    if (l.recent_id.len > 0) {
      l.cur_stored = cur.*;
      return true;
    } else return false;
  }

  fn readNumber(l: *Lexer, cur: *u21) void {
    l.code_point = cur.* - '0';
    while (true) {
      cur.* = l.walker.nextInline() catch |e| {
        l.cur_stored = e;
        return;
      };
      if (cur.* < '0' or cur.* > '9') break;
      l.code_point = l.code_point * 10 + (cur.* - '0');
    }
    l.cur_stored = cur.*;
  }

  inline fn advancing(l: *Lexer, cur: *u21, f: @TypeOf(Walker.nextInline))
      !bool {
    cur.* = f(&l.walker) catch |e| {
      if (l.recent_end.byte_offset != l.walker.before.byte_offset) {
        l.cur_stored = e;
        return true;
      } else {
        l.cur_stored = l.walker.nextInline();
        return e;
      }
    };
    return false;
  }

  /// return true iff any space has been read.
  /// error is only returned if no space has been read.
  fn readDumpableSpace(l: *Lexer, cur: *u21) !bool {
    while(true) {
      switch (cur.*) {
        '\r' => {
          if (try l.advancing(cur, Walker.nextAfterCR)) return true;
        },
        '\n' => {
          if (try l.advancing(cur, Walker.nextAfterLF)) return true;
        },
        '\t', ' ' => {
          if (try l.advancing(cur, Walker.nextInline)) return true;
        },
        else => break,
      }
    }
    if (l.recent_end.byte_offset != l.walker.before.byte_offset) {
      l.cur_stored = cur.*;
      return true;
    } else return false;
  }

  inline fn checkEndCommand(l: *Lexer) bool {
    l.walker.mark();
    defer {
      l.walker.resetToMark();
    }
    var lookahead = l.walker.nextInline() catch return false;
    if (lookahead != 'e') return false;
    lookahead = l.walker.nextInline() catch return false;
    if (lookahead != 'n') return false;
    lookahead = l.walker.nextInline() catch return false;
    if (lookahead != 'd') return false;
    lookahead = l.walker.nextInline() catch return false;
    if (lookahead != '(') return false;
    l.cur_stored = l.walker.nextInline();
    if (l.matchEndCommand(false) != .call_id) return false;
    lookahead = l.cur_stored catch return false;
    return lookahead == ')';
  }

  fn matchEndCommand(l: *Lexer, search_skipped: bool) Token {
    var cur = l.cur_stored;
    while (cur) |val| {
      if (val != '\t' and val != ' ') break;
      cur = l.walker.nextInline();
    } else |_| {}
    const start = l.walker.before.byte_offset;
    while (true) {
      const val = cur catch break;
      if (!unicode.L.contains(unicode.category(val))) break;
      cur = l.walker.nextInline();
    }
    l.recent_id = l.walker.contentFrom(start);
    while (cur) |val| {
      if (val != '\t' and val != ' ') break;
      cur = l.walker.nextInline();
    } else |_| {}
    var ret: Token = undefined;
    l.cur_stored = cur;
    if (std.mem.eql(u8, l.level.id, l.recent_id)) {
      ret = .call_id;
    } else {
      ret = .skipping_call_id;
      var found = false;
      if (search_skipped) {
        var i = l.levels.items.len;
        while (i > 0) {
          i -= 1;
          if (std.mem.eql(u8, l.levels.items[i].id, l.recent_id)) {
            found = true;
            break;
          }
          ret = @intToEnum(Token, @enumToInt(ret) + 1);
        }
      }
      if (!found) {
        return .wrong_call_id;
      }
    }
    return ret;
  }

  fn exprContinuation(l: *Lexer, cur: *u21, after_arglist: bool) !?Token {
    switch(cur.*) {
      '(' => {
        if (after_arglist) {
          l.level = .{
            .indentation = undefined,
            .tabs = null,
            .id = "",
            .end_char = l.level.end_char,
            .special = .disabled,
          };
        } else {
          try l.pushLevel();
        }
        l.paren_depth += 1;
        l.cur_stored = l.walker.nextInline();
        l.state = .arg_start;
        return .list_start;
      },
      ':' => {
        cur.* = l.walker.nextInline() catch |e| {
          l.cur_stored = e;
          if (l.paren_depth == 0) {
            if (!after_arglist) try l.pushLevel();
            return .blocks_sep;
          } else {
            l.state = .in_arg;
            return .illegal_blocks_start_in_args;
          }
        };
        switch(cur.*) {
          ':' => {
            l.cur_stored = l.walker.nextInline();
            l.state = .after_access_colons;
            return .access;
          },
          ',' => {
            l.cur_stored = l.walker.nextInline();
            l.state = l.curBaseState();
            return .closer;
          },
          '=' => {
            l.cur_stored = l.walker.nextInline();
            l.state = .after_assign;
            return .assign;
          },
          else => {
            l.cur_stored = cur.*;
            if (l.paren_depth == 0) {
              if (!after_arglist) try l.pushLevel();
              l.state = .after_blocks_colon;
              return .blocks_sep;
            } else {
              l.state = .in_arg;
              return .illegal_blocks_start_in_args;
            }
          },
        }
      },
      else => {
        return null;
      }
    }
  }

  fn pushLevel(l: *Lexer) !void {
    try l.levels.append(l.intpr.allocator(), l.level);
    l.level = .{
      .indentation = undefined,
      .tabs = null,
      .id = l.recent_id,
      .end_char = l.code_point,
      .special = .disabled,
    };
  }

  inline fn curBaseState(l: *Lexer) State {
    return if (l.paren_depth > 0) .in_arg
           else if (l.level.special == .disabled) State.in_block
           else State.special_syntax;
  }

  pub fn disableColons(l: *Lexer) void {
    if (l.colons_disabled_at == null) {
      l.colons_disabled_at = l.levels.items.len;
    }
  }

  pub fn disableComments(l: *Lexer) void {
    if (l.comments_disabled_at == null) {
      l.comments_disabled_at = l.levels.items.len;
    }
  }

  pub fn enableSpecialSyntax(l: *Lexer, comments_include_newline: bool) void {
    std.debug.print(
      "  lex: enabling special syntax at state {s}\n", .{@tagName(l.state)});
    l.level.special = if (comments_include_newline) .standard_comments
                      else .comments_without_newline;
    std.debug.assert(l.state == .check_indent);
    l.state = .special_syntax_check_indent;
  }

  pub fn readBlockHeader(l: *Lexer) void {
    std.debug.assert(l.state == .special_syntax);
    l.state = .after_blocks_colon;
  }
};