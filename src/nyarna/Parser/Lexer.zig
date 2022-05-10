const std = @import("std");

const nyarna      = @import("../../nyarna.zig");
const unicode     = @import("../unicode.zig");

const EncodedCharacter = unicode.EncodedCharacter;
const Interpreter      = nyarna.Interpreter;
const model            = nyarna.model;
const Token            = model.Token;

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
      1    => return @intCast(u21, w.cur[0]),
      2    => return std.unicode.utf8Decode2(w.cur[0..2]),
      3    => return std.unicode.utf8Decode3(w.cur[0..3]),
      4    => return std.unicode.utf8Decode4(w.cur[0..4]),
      else => unreachable,
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

  pub fn contentIn(w: *Walker, pos: model.Position) []const u8 {
    return w.source.content[pos.start.byte_offset..pos.end.byte_offset];
  }

  pub fn lastUtf8Unit(w: *Walker) []const u8 {
    return (w.cur - w.recent_length)[0..w.recent_length];
  }

  pub fn posFrom(w: *Walker, start: model.Cursor) model.Position {
    return .{.source = w.source.meta, .start = start, .end = w.before};
  }
};

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

pub const Lexer = @This();

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
    .intpr       = intpr,
    .cur_stored  = undefined,
    .state       = .indent_capture,
    .walker      = Walker.init(intpr.input),
    .paren_depth = 0,
    .colons_disabled_at   = null,
    .comments_disabled_at = null,
    .levels =
      try std.ArrayListUnmanaged(Level).initCapacity(
        intpr.allocator, 32),
    .level = .{
      .indentation = 0,
      .tabs        = null,
      .id          = undefined,
      .end_char    = undefined,
      .special     = .disabled,
    },
    .newline_count      = 0,
    .recent_end         = undefined,
    .recent_id          = undefined,
    .recent_expected_id = undefined,
    .line_start         = undefined,
    .indent_char_seen   = undefined,
    .code_point         = undefined,
    .ns                 = undefined,
  };
  ret.cur_stored = ret.walker.nextInline();
  ret.recent_end = ret.walker.before;
  return ret;
}

pub fn deinit(_: *Lexer) void {
  // nothing to do – all allocated data managed by upstream Interpreter.
}

/// assumes current character is '#'.
/// Reads comment content according to [7.5.1].
/// Returns true iff comment includes newline character.
inline fn readComment(self: *Lexer, cur: *u21) bool {
  cur.* = self.walker.nextInline() catch |e| {
    self.cur_stored = e;
    return false;
  };
  while (true) {
    switch (cur.*) {
      '#' => while (true) {
        cur.* = self.walker.nextInline() catch |e| {
          self.cur_stored = e;
          return false;
        };
        switch (cur.*) {
          ' ', '\t' => {},
          '\r', '\n' => {
            self.cur_stored = cur.*;
            return false;
          },
          else => break,
        }
      },
      '\r' => {
        if (self.level.special == .comments_without_newline) {
          self.cur_stored = cur.*;
          return false;
        } else {
          self.cur_stored = self.walker.nextAfterCR();
          return true;
        }
      },
      '\n' => {
        if (self.level.special == .comments_without_newline) {
          self.cur_stored = cur.*;
          return false;
        } else {
          self.cur_stored = self.walker.nextAfterLF();
          return true;
        }
      },
      else => cur.* = self.walker.nextInline() catch |e| {
        self.cur_stored = e;
        return false;
      },
    }
  }
}

/// starts at cur character. while cur is newline, space or tab,
/// read next character into cur. return number of newlines seen,
/// while storing the beginning of the current line into l.line_start.
inline fn emptyLines(self: *Lexer, cur: *u21) u16 {
  var newlines_seen: u16 = 0;
  self.line_start = self.walker.before;
  while (true) {
    switch (cur.*) {
      '\t' => {
        self.indent_char_seen.tab = true;
      },
      ' '  => {
        self.indent_char_seen.space = true;
      },
      '\r' => {
        newlines_seen += 1;
        self.indent_char_seen = .{.space = false, .tab = false};
        cur.* = self.walker.nextAfterCR() catch |e| {
          self.cur_stored = e;
          self.line_start = self.walker.before;
          return newlines_seen;
        };
        self.line_start = self.walker.before;
        continue;
      },
      '\n' => {
        newlines_seen += 1;

        self.indent_char_seen = .{.space = false, .tab = false};
        cur.* = self.walker.nextAfterLF() catch |e| {
          self.cur_stored = e;
          self.line_start = self.walker.before;
          return newlines_seen;
        };
        self.line_start = self.walker.before;
        continue;
      },
      else => break,
    }
    cur.* = self.walker.nextInline() catch |e| {
      self.cur_stored = e;
      return newlines_seen;
    };
  }
  self.cur_stored = cur.*;
  return newlines_seen;
}

/// transition to a new state via the offset between base_from and base_to.
/// used for transparently handling special_syntax transitions.
inline fn transition(
           self     : *Lexer,
  comptime base_from: State,
           base_to  : State,
) void {
  self.state = @intToEnum(State,
    @enumToInt(self.state) + (@enumToInt(base_to) - @enumToInt(base_from)));
}

inline fn procIndentCapture(self: *Lexer, cur: *u21) ?Token {
  switch (cur.*) {
    4 => return .end_source,
    '#' => {
      if (self.newline_count > 0) {
        self.recent_end = self.walker.before;
        self.newline_count = 0;
        return .space;
      }
      _ = self.readComment(cur);
      self.recent_end = self.walker.before;
      return .comment;
    },
    else => {
      self.newline_count += self.emptyLines(cur);
      self.transition(.indent_capture, .check_indent);
      if (self.newline_count > 0) {
        self.recent_end = self.line_start;
        return .space;
      } else return null;
    }
  }
}

inline fn procCheckIndent(self: *Lexer, cur: *u21) ?Token {
  if (cur.* == 4) return .end_source;
  self.transition(
    .check_indent, if (self.colons_disabled_at == null)
      State.check_block_name else .in_block);
  if (self.recent_end.byte_offset != self.walker.before.byte_offset) {
    self.level.indentation = @intCast(
      u16, self.recent_end.byte_offset - self.line_start.byte_offset);
    self.recent_end = self.walker.before;
    if (self.indent_char_seen.tab and self.indent_char_seen.space) {
      return .mixed_indentation;
    } else if (self.level.tabs) |tabs| {
      return if (tabs == self.indent_char_seen.space) .illegal_indentation
      else .indent;
    } else {
      self.level.tabs = self.indent_char_seen.tab;
      return .indent;
    }
  } return null;
}

inline fn procCheckParsep(self: *Lexer, cur: *u21) ?Token {
  const newlines = self.emptyLines(cur);
  self.recent_end = self.line_start;
  self.transition(.check_parsep, .check_indent);
  if (newlines > 0) {
    self.newline_count += newlines;
    return .parsep;
  } else if (self.newline_count > 0) {
    return .ws_break;
  } else return null;
}

inline fn procCheckBlockName(self: *Lexer, cur: *u21) ?Token {
  if (cur.* == ':') {
    self.state = .read_block_name;
    self.cur_stored = self.walker.nextInline();
    self.recent_end = self.walker.before;
    // if previous block disabled comments, re-enable them. this needs
    // not be done for disabled colons, because if colons are disabled,
    // we would never end up here.
    if (self.comments_disabled_at) |depth| {
      if (depth == self.levels.items.len) self.comments_disabled_at = null;
    }
    // if previous block had special syntax, disable it.
    self.level.special = .disabled;
    return .block_name_sep;
  }
  self.transition(.check_block_name, .in_block);
  return null;
}

inline fn procBlock(self: *Lexer, cur: *u21) !?Token {
  const res =
    if (self.state == .in_block) try self.processContent(.block, cur)
    else try self.processContent(.special, cur);
  if (res.hit_line_end) self.transition(.in_block, .check_parsep);
  if (res.token) |t| {
    self.recent_end = self.walker.before;
    return t;
  } else {
    cur.* = self.cur_stored catch {
      self.recent_end = self.walker.before;
      return .ws_break;
    };
    return null;
  }
}

inline fn procArg(self: *Lexer, cur: *u21) !Token {
  const res = try self.processContent(.args, cur);
  self.recent_end = self.walker.before;
  return if (res.token) |t| t else .ws_break;
}

inline fn procArgStart(self: *Lexer, cur: *u21) !?Token {
  if (try self.readDumpableSpace(cur)) {
    self.recent_end = self.walker.before;
    return .space;
  }
  switch (cur.*) {
    4 => return .end_source,
    '=' => {
      self.cur_stored = self.walker.nextInline();
      self.recent_end = self.walker.before;
      self.state = .before_id_setter;
      return .id_set;
    },
    else => {
      self.state = .in_arg;
      return null;
    },
  }
}

inline fn procBeforeIdSetter(self: *Lexer, cur: *u21) !?Token {
  if (try self.readDumpableSpace(cur)) {
    self.recent_end = self.walker.before;
    return .space;
  }
  self.state = .in_arg;
  if (self.readIdentifier(cur)) {
    // while the call ID must be recognized by the lexer to be able to
    // close the command later, we parse additional (illegal) content
    // normally. The parser will produce appropriate errors.
    self.recent_end = self.walker.before;
    self.level.id = self.recent_id;
    return .call_id;
  } else {
    // no proper ID, therefore level ID is not changed. Just emit the
    // rest of the content normally, parser will report an error.
    return null;
  }
}

inline fn procAfterAccessColons(self: *Lexer, cur: *u21) ?Token {
  if (self.readIdentifier(cur)) {
    self.state = .after_id;
    self.recent_end = self.walker.before;
    return .identifier;
  }
  self.state = self.curBaseState();
  return null;
}

inline fn procAfterAssign(self: *Lexer, cur: *u21) !?Token {
  if (try self.exprContinuation(cur, false)) |t| {
    self.recent_end = self.walker.before;
    return t;
  }
  self.state = self.curBaseState();
  if (self.cur_stored) return null else |e| {
    self.cur_stored = self.walker.nextInline();
    return e;
  }
}

inline fn procReadBlockName(self: *Lexer, cur: *u21) !Token {
  const res = try self.processContent(.block_name, cur);
  if (res.hit_line_end) {
    std.debug.assert(res.token == null);
    self.newline_count = 1;
    self.state = .indent_capture;
    self.recent_end = self.walker.before;
    return .missing_block_name_sep;
  }
  self.recent_end = self.walker.before;
  return res.token.?;
}

inline fn procAfterId(self: *Lexer, cur: *u21) !?Token {
  if (try self.exprContinuation(cur, false)) |t| {
    self.recent_end = self.walker.before;
    return t;
  } else {
    self.state = self.curBaseState();
    return null;
  }
}

inline fn procAfterArgs(self: *Lexer, cur: *u21) !?Token {
  if (try self.exprContinuation(cur, true)) |t| {
    self.recent_end = self.walker.before;
    return t;
  } else {
    self.level = self.levels.pop();
    self.state = self.curBaseState();
    return null;
  }
}

inline fn procAfterBlocksColon(self: *Lexer, cur: *u21) ?Token {
  switch (cur.*) {
    '<' => {
      self.state = .config_item_start;
      self.cur_stored = self.walker.nextInline();
      self.recent_end = self.walker.before;
      return .diamond_open;
    },
    '>' => {
      self.state =
        if (self.level.special == .disabled) .at_header else .special_syntax;
      self.cur_stored = self.walker.nextInline();
      self.recent_end = self.walker.before;
      return .diamond_close;
    },
    '0'...'9' => {
      self.readNumber(cur); // assigns to l.cur_stored
      self.state = .after_depth;
      self.recent_end = self.walker.before;
      return .swallow_depth;
    },
    else => {
      self.state =
        if (self.level.special == .disabled) .at_header else .special_syntax;
      return null;
    },
  }
}

inline fn procAtHeader(self: *Lexer, cur: *u21) !?Token {
  const res = try self.processContent(.block, cur);
  if (res.hit_line_end) {
    self.newline_count = 1;
    self.state = .indent_capture;
  } else {
    // ignore proposed state changes, e.g. from encountering a command.
    // anything that would cause a state change is illegal content here.
    self.state = .at_header;
  }
  self.recent_end = self.walker.before;
  if (res.token) |t| {
    return switch (t) {
      .space, .comment, .end_source, .illegal_code_point => t,
      .ws_break => .space,
      else => .illegal_content_at_header,
    };
  } else {
    cur.* = self.cur_stored catch {
      return .space;
    };
    return null;
  }
}

inline fn procConfigItemStart(self: *Lexer, cur: *u21) !Token {
  if (try self.readDumpableSpace(cur)) {
    self.recent_end = self.walker.before;
    return .space;
  }
  if (cur.* == '>') {
    self.cur_stored = self.walker.nextInline();
    self.state = .after_config;
    return .diamond_close;
  }
  if (!self.readIdentifier(cur)) {
    // we always emit .identifier here, even if it has 0 length.
    // if reading an identifier fails, we need to store cur manually
    // while this is done automatically on success.
    self.cur_stored = cur.*;
  }
  self.state = .config_item_arg;
  self.recent_end = self.walker.before;
  return .identifier;
}

inline fn procConfigItemArg(self: *Lexer, cur: *u21) !?Token {
  const res = try self.processContent(.config, cur);
  self.recent_end = self.walker.before;
  if (res.token) |t| return t
  else {
    cur.* = self.cur_stored catch {
      return .space;
    };
    return null;
  }
}

inline fn procAfterConfig(self: *Lexer, cur: *u21) ?Token {
  if (cur.* == ':') {
    self.state = .after_blocks_colon;
    self.cur_stored = self.walker.nextInline();
    self.recent_end = self.walker.before;
    return .blocks_sep;
  } else {
    self.state =
      if (self.level.special == .disabled) .at_header else .special_syntax;
    return null;
  }
}

inline fn procAfterDepth(self: *Lexer, cur: *u21) ?Token {
  self.state =
    if (self.level.special == .disabled) .at_header else .special_syntax;
  if (cur.* == '>') {
    self.cur_stored = self.walker.nextInline();
    self.recent_end = self.walker.before;
    return .diamond_close;
  } else return null;
}

inline fn procBeforeEndId(self: *Lexer) Token {
  var res = self.matchEndCommand(true);
  if (res == .call_id) {
    self.level = self.levels.pop();
  } else {
    self.recent_expected_id = self.level.id;
    if (res == .wrong_call_id and self.levels.items.len == 0) {
      res = .no_block_call_id;
    }  else {
      var i = @enumToInt(res) + 1;
      while (i >= @enumToInt(Token.skipping_call_id)) : (i = i - 1) {
        self.level = self.levels.pop();
      }
    }
  }
  if (self.comments_disabled_at) |depth| {
    if (self.levels.items.len < depth) {
      self.comments_disabled_at = null;
    }
  }
  if (self.colons_disabled_at) |depth| {
    if (self.levels.items.len < depth) {
      self.colons_disabled_at = null;
    }
  }
  self.state = .after_end_id;
  self.recent_end = self.walker.before;
  return res;
}

inline fn procAfterEndId(self: *Lexer, cur: *u21) ?Token {
  if (cur.* == ')') {
    self.cur_stored = self.walker.nextInline();
    self.recent_end = self.walker.before;
    self.state = .after_id;
    self.recent_id = "";
    return .list_end;
  } else {
    // this will be recognized as error by the parser.
    self.state = .in_block;
    return null;
  }
}

pub fn next(self: *Lexer) !Token {
  var cur = self.cur_stored catch |e| {
    self.cur_stored = self.walker.nextInline();
    return e;
  };
  while (true) switch (self.state) {
    .indent_capture, .special_syntax_indent_capture =>
      if (self.procIndentCapture(&cur)) |t| return t,
    .check_indent, .special_syntax_check_indent =>
      if (self.procCheckIndent(&cur)) |t| return t,
    .check_parsep, .special_syntax_check_parsep =>
      if (self.procCheckParsep(&cur)) |t| return t,
    .check_block_name, .special_syntax_check_block_name =>
      if (self.procCheckBlockName(&cur)) |t| return t,
    .in_block, .special_syntax =>
      if (try self.procBlock(&cur)) |t| return t,
    .in_arg => return try self.procArg(&cur),
    .arg_start => if (try self.procArgStart(&cur)) |t| return t,
    .before_id_setter =>
      if (try self.procBeforeIdSetter(&cur)) |t| return t,
    .after_access_colons =>
      if (self.procAfterAccessColons(&cur)) |t| return t,
    .after_assign => if (try self.procAfterAssign(&cur)) |t| return t,
    .read_block_name => return try self.procReadBlockName(&cur),
    .after_id => if (try self.procAfterId(&cur)) |t| return t,
    .after_args => if (try self.procAfterArgs(&cur)) |t| return t,
    .after_blocks_colon =>
      if (self.procAfterBlocksColon(&cur)) |t| return t,
    .at_header => if (try self.procAtHeader(&cur)) |t| return t,
    .config_item_start => return try self.procConfigItemStart(&cur),
    .config_item_arg => if (try self.procConfigItemArg(&cur)) |t| return t,
    .after_config => if (self.procAfterConfig(&cur)) |t| return t,
    .after_depth => if (self.procAfterDepth(&cur)) |t| return t,
    .before_end_id => return self.procBeforeEndId(),
    .after_end_id => if (self.procAfterEndId(&cur)) |t| return t,
  };
}

const Surrounding = enum {block, args, config, block_name, special};
const ContentResult = struct {
  hit_line_end: bool = false,
  token: ?Token = null
};

inline fn hitLineEnd(self: *Lexer, cr: bool) ContentResult {
  self.cur_stored =
    if (cr) self.walker.nextAfterCR() else self.walker.nextAfterLF();
  self.newline_count = 1;
  return ContentResult{.hit_line_end = true};
}

inline fn hitCommentChar(
           self: *Lexer,
  comptime ctx : Surrounding,
           cur : *u21,
) ?ContentResult {
  switch (ctx) {
    .block_name => return null,
    .config => {
      self.cur_stored = self.walker.nextInline();
      return ContentResult{.token = .comment};
    },
    .special => {
      if (self.comments_disabled_at != null) {
        self.code_point =  cur.*;
        self.cur_stored = self.walker.nextInline();
        return ContentResult{.token = .special};
      } else {
        const line_end = self.readComment(cur);
        self.newline_count = 0;
        return ContentResult{.hit_line_end = line_end, .token = .comment};
      }
    },
    else => {
      if (self.comments_disabled_at != null) {
        self.readLiteral(ctx, cur);
        return ContentResult{.token = .literal};
      } else {
        const line_end = self.readComment(cur);
        self.newline_count = 0;
        return ContentResult{.hit_line_end = line_end, .token = .comment};
      }
    }
  }
}

inline fn hitWhitespace(self: *Lexer, cur: *u21) ContentResult {
  while (true) {
    cur.* = self.walker.nextInline() catch |e| {
      self.cur_stored = e;
      return ContentResult{.token = .space};
    };
    if (cur.* != '\t' and cur.* != ' ') break;
  }
  self.cur_stored = cur.*;
  return ContentResult{.token = .space};
}

inline fn hitColon(
           self: *Lexer,
  comptime ctx : Surrounding,
           cur : *u21,
) ?ContentResult {
  switch (ctx) {
    .block_name =>
      return self.advanceAndReturn(.block_name_sep, .after_blocks_colon),
    .args => {
      cur.* = self.walker.nextInline() catch |e| {
        self.cur_stored = e;
        return ContentResult{.token = .literal};
      };
      if (cur.* == '=') {
        return self.advanceAndReturn(.name_sep, null);
      }
      return null;
    },
    .config => {
      self.cur_stored = self.walker.nextInline();
      return ContentResult{.token = .block_name_sep};
    },
    else => return null,
  }
}

/// return null for an unescaped line end since it may be part of a parsep.
/// hit_line_end is true if the recently processed character was a line break.
inline fn processContent(
           self: *Lexer,
  comptime ctx : Surrounding,
           cur : *u21,
) !ContentResult {
  switch (cur.*) {
    4 => return ContentResult{.token = .end_source},
    '\r' => return self.hitLineEnd(true),
    '\n' => return self.hitLineEnd(false),
    '#' => if (self.hitCommentChar(ctx, cur)) |res| return res,
    '\t', ' ' => return self.hitWhitespace(cur),
    0...3, 5...8, 11...12, 14...31 => {
      return self.advanceAndReturn(.illegal_code_point, null);
    },
    '>' => if (ctx == .config) {
      return self.advanceAndReturn(.diamond_close, .after_config);
    },
    ':' => if (self.hitColon(ctx, cur)) |res| return res,
    ',' => if (ctx == .args or ctx == .config) {
      return self.advanceAndReturn(.comma,
          if (ctx == .config) .config_item_start else .arg_start);
    },
    '=' => if (ctx == .args) {
      return self.advanceAndReturn(.name_sep, null);
    },
    '(' => if (ctx == .args) {
      return self.advanceAndReturn(.illegal_opening_parenthesis, null);
    },
    ')' => if (ctx == .args) {
      self.paren_depth -= 1;
      return self.advanceAndReturn(.list_end, .after_args);
    },
    else => {}
  }
  switch (ctx) {
    .config => if (unicode.MPS.contains(unicode.category(cur.*))) {
      self.code_point = cur.*;
      return self.advanceAndReturn(.ns_sym, null);
    },
    .block_name => {},
    else => if (self.intpr.command_characters.get(cur.*)) |ns| {
      self.ns = ns;
      return self.genCommand(cur, ctx != .args);
    } else if (cur.* == self.level.end_char and self.checkEndCommand()) {
      return self.genCommand(cur, ctx != .args);
    },
  }

  switch (ctx) {
    .block_name => {
      if (self.readIdentifier(cur)) {
        return ContentResult{.token = .identifier};
      }
      while (true) {
        cur.* = self.walker.nextInline() catch |e| {
          self.cur_stored = e;
          self.recent_end = self.walker.before;
          return ContentResult{.token = .illegal_characters};
        };
        switch (cur.*) {
          4, ' ', '\t', '\r', '\n', ':' => break,
          else => {
            if (unicode.L.contains(unicode.category(cur.*))) break;
          }
        }
      }
      self.cur_stored = cur.*;
      return ContentResult{.token = .illegal_characters};
    },
    .special => {
      if (self.readIdentifier(cur)) {
        return ContentResult{.token = .identifier};
      }
      self.code_point = cur.*;
      self.cur_stored = self.walker.nextInline();
      return ContentResult{.token = .special};
    },
    else => {
      self.readLiteral(ctx, cur);
      return ContentResult{.token = .literal};
    },
  }
}

inline fn advanceAndReturn(
           self     : *Lexer,
           value    : Token,
  comptime new_state: ?State,
) ContentResult {
  self.cur_stored = self.walker.nextInline();
  if (new_state) |state| {
    self.state = state;
  }
  return .{.token = value};
}

fn readLiteral(
           self: *Lexer,
  comptime ctx : Surrounding,
           cur : *u21,
) void {
  while (true) {
    switch (cur.*) {
      0...32 => break,
      '#' => if (self.comments_disabled_at == null) break,
      '>' => if (ctx == .config) break,
      ':' => switch (ctx) {
        .block_name => break,
        .args       => {
          self.walker.mark();
          cur.* = self.walker.nextInline() catch |e| {
            self.cur_stored = e;
            return;
          };
          if (cur.* == '=') {
            self.walker.resetToMark();
            cur.* = ':';
            break;
          } else continue;
        },
        else => {},
      },
      ',' => if (ctx == .args or ctx == .config) break,
      '=', '(', ')' => if (ctx == .args) break,
      else => if (self.intpr.command_characters.contains(cur.*)) break,
    }
    cur.* = self.walker.nextInline() catch |e| {
      self.cur_stored = e;
      return;
    };
  }
  self.cur_stored = cur.*;
}

fn genCommand(
  self       : *Lexer,
  cur        : *u21,
  end_allowed: bool,
) ContentResult {
  self.code_point = cur.*;
  cur.* = self.walker.nextInline() catch |e| {
    self.cur_stored = e;
    return .{.token = .illegal_command_char};
  };
  if (self.readIdentifier(cur)) {
    if (std.mem.eql(u8, self.recent_id, "end")) {
      if (cur.* == '(') {
        self.cur_stored = self.walker.nextInline();
        if (end_allowed) {
          self.state = .before_end_id;
          return .{.token = .block_end_open};
        } else {
          cur.* = self.cur_stored
            catch return .{.token = .invalid_end_command};
          while (
            cur.* == ' ' or cur.* == '\t' or
            unicode.L.contains(unicode.category(cur.*))
          ) {
            cur.* = self.walker.nextInline() catch |e| {
              self.cur_stored = e;
              return .{.token = .invalid_end_command};
            };
          }
          self.cur_stored =
            if (cur.* == ')') self.walker.nextInline() else cur.*;
          return .{.token = .invalid_end_command};
        }
      } else {
        return .{.token = .invalid_end_command};
      }
    } else {
      self.state = .after_id;
      self.cur_stored = cur.*;
      return .{.token = .symref};
    }
  } else switch (cur.*) {
    '\r' => {
      self.cur_stored = self.walker.nextAfterCR();
      self.recent_end = self.walker.before;
      self.newline_count = 0;
      self.recent_id = newline;
      return .{.hit_line_end = true, .token = .escape};
    },
    '\n' => {
      self.cur_stored = self.walker.nextAfterLF();
      self.recent_end = self.walker.before;
      self.newline_count = 0;
      self.recent_id = newline;
      return .{.hit_line_end = true, .token = .escape};
    },
    '\t', ' ' => {
      self.recent_id = self.walker.lastUtf8Unit();
      cur.* = self.walker.nextInline() catch |e| {
        self.cur_stored = e;
        self.recent_end = self.walker.before;
        return .{.token = .escape};
      };
      self.walker.mark();
      while (cur.* == '\t' or cur.* == ' ') {
        cur.* = self.walker.nextInline() catch {
          break;
        };
      }
      if (cur.* == '\r') {
        self.cur_stored = self.walker.nextAfterCR();
        self.recent_id = newline;
      } else if (cur.* == '\n') {
        self.cur_stored = self.walker.nextAfterLF();
        self.recent_id = newline;
      } else {
        self.walker.resetToMark();
        self.cur_stored = self.walker.nextInline();
        self.recent_end = self.walker.before;
        return .{.token = .escape};
      }
      self.recent_end = self.walker.before;
      self.newline_count = 0;
      return .{.hit_line_end = true, .token = .escape};
    },
    else => {
      self.recent_id = self.walker.lastUtf8Unit();
      self.cur_stored = self.walker.nextInline();
      self.recent_end = self.walker.before;
      return .{.token = .escape};
    }
  }
}

/// attempts to read an identifier. returns true iff at least one character
/// has been read as identifier. l.cur_stored has been updated if returning
/// true.
fn readIdentifier(self: *Lexer, cur: *u21) bool {
  const name_start = self.walker.before.byte_offset;
  while (unicode.L.contains(unicode.category(cur.*))) {
    cur.* = self.walker.nextInline() catch |e| {
      self.cur_stored = e;
      const len = self.walker.before.byte_offset - name_start;
      self.recent_id = (self.walker.cur - len)[0..len];
      return true;
    };
  }
  self.recent_id = self.walker.contentFrom(name_start);
  if (self.recent_id.len > 0) {
    self.cur_stored = cur.*;
    return true;
  } else return false;
}

fn readNumber(self: *Lexer, cur: *u21) void {
  self.code_point = cur.* - '0';
  while (true) {
    cur.* = self.walker.nextInline() catch |e| {
      self.cur_stored = e;
      return;
    };
    if (cur.* < '0' or cur.* > '9') break;
    self.code_point = self.code_point * 10 + (cur.* - '0');
  }
  self.cur_stored = cur.*;
}

inline fn advancing(
  self: *Lexer,
  cur : *u21,
  f   : @TypeOf(Walker.nextInline),
) !bool {
  cur.* = f(&self.walker) catch |e| {
    if (self.recent_end.byte_offset != self.walker.before.byte_offset) {
      self.cur_stored = e;
      return true;
    } else {
      self.cur_stored = self.walker.nextInline();
      return e;
    }
  };
  return false;
}

/// return true iff any space has been read.
/// error is only returned if no space has been read.
fn readDumpableSpace(self: *Lexer, cur: *u21) !bool {
  while(true) {
    switch (cur.*) {
      '\r' => {
        if (try self.advancing(cur, Walker.nextAfterCR)) return true;
      },
      '\n' => {
        if (try self.advancing(cur, Walker.nextAfterLF)) return true;
      },
      '\t', ' ' => {
        if (try self.advancing(cur, Walker.nextInline)) return true;
      },
      else => break,
    }
  }
  if (self.recent_end.byte_offset != self.walker.before.byte_offset) {
    self.cur_stored = cur.*;
    return true;
  } else return false;
}

inline fn checkEndCommand(self: *Lexer) bool {
  self.walker.mark();
  defer {
    self.walker.resetToMark();
  }
  var lookahead = self.walker.nextInline() catch return false;
  if (lookahead != 'e') return false;
  lookahead = self.walker.nextInline() catch return false;
  if (lookahead != 'n') return false;
  lookahead = self.walker.nextInline() catch return false;
  if (lookahead != 'd') return false;
  lookahead = self.walker.nextInline() catch return false;
  if (lookahead != '(') return false;
  self.cur_stored = self.walker.nextInline();
  if (self.matchEndCommand(false) != .call_id) return false;
  lookahead = self.cur_stored catch return false;
  return lookahead == ')';
}

fn matchEndCommand(self: *Lexer, search_skipped: bool) Token {
  var cur = self.cur_stored;
  while (cur) |val| {
    if (val != '\t' and val != ' ') break;
    cur = self.walker.nextInline();
  } else |_| {}
  const start = self.walker.before.byte_offset;
  while (true) {
    const val = cur catch break;
    if (!unicode.L.contains(unicode.category(val))) break;
    cur = self.walker.nextInline();
  }
  self.recent_id = self.walker.contentFrom(start);
  while (cur) |val| {
    if (val != '\t' and val != ' ') break;
    cur = self.walker.nextInline();
  } else |_| {}
  var ret: Token = undefined;
  self.cur_stored = cur;
  if (std.mem.eql(u8, self.level.id, self.recent_id)) {
    ret = .call_id;
  } else {
    ret = .skipping_call_id;
    var found = false;
    if (search_skipped) {
      var i = self.levels.items.len;
      while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, self.levels.items[i].id, self.recent_id)) {
          found = true;
          break;
        }
        ret = @intToEnum(Token, @enumToInt(ret) + 1);
      }
    }
    if (!found) return .wrong_call_id;
  }
  return ret;
}

fn exprContinuation(self: *Lexer, cur: *u21, after_arglist: bool) !?Token {
  switch (cur.*) {
    '(' => {
      if (after_arglist) {
        self.level = .{
          .indentation = undefined,
          .tabs = null,
          .id = "",
          .end_char = self.level.end_char,
          .special = .disabled,
        };
      } else {
        try self.pushLevel();
      }
      self.paren_depth += 1;
      self.cur_stored = self.walker.nextInline();
      self.state = .arg_start;
      return .list_start;
    },
    ':' => {
      cur.* = self.walker.nextInline() catch |e| {
        self.cur_stored = e;
        if (self.paren_depth == 0) {
          if (!after_arglist) try self.pushLevel();
          return .blocks_sep;
        } else {
          self.state = .in_arg;
          return .illegal_blocks_start_in_args;
        }
      };
      switch (cur.*) {
        ':' => {
          self.cur_stored = self.walker.nextInline();
          self.state = .after_access_colons;
          return .access;
        },
        ',' => {
          self.cur_stored = self.walker.nextInline();
          self.state = self.curBaseState();
          return .closer;
        },
        '=' => {
          self.cur_stored = self.walker.nextInline();
          self.state = .after_assign;
          return .assign;
        },
        else => {
          self.cur_stored = cur.*;
          if (self.paren_depth == 0) {
            if (!after_arglist) try self.pushLevel();
            self.state = .after_blocks_colon;
            return .blocks_sep;
          } else {
            self.state = .in_arg;
            return .illegal_blocks_start_in_args;
          }
        },
      }
    },
    0...3, 5...8, 11...12, 14...31 => {
      self.cur_stored = self.walker.nextInline();
      return .illegal_code_point;
    },
    else => {
      return null;
    }
  }
}

fn pushLevel(self: *Lexer) !void {
  try self.levels.append(self.intpr.allocator, self.level);
  self.level = .{
    .indentation = undefined,
    .tabs = null,
    .id = self.recent_id,
    .end_char = self.code_point,
    .special = .disabled,
  };
}

inline fn curBaseState(self: *Lexer) State {
  return if (self.paren_depth > 0) (
    State.in_arg
  ) else if (self.level.special == .disabled) (
    State.in_block
  ) else State.special_syntax;
}

pub fn disableColons(self: *Lexer) void {
  if (self.colons_disabled_at == null) {
    self.colons_disabled_at = self.levels.items.len;
  }
}

pub fn disableComments(self: *Lexer) void {
  if (self.comments_disabled_at == null) {
    self.comments_disabled_at = self.levels.items.len;
  }
}

pub fn enableSpecialSyntax(
  self                    : *Lexer,
  comments_include_newline: bool,
) void {
  self.level.special =
    if (comments_include_newline) .standard_comments
    else .comments_without_newline;
  std.debug.assert(
    self.state == .check_indent or (self.cur_stored catch 0) == 4);
  self.state = .special_syntax_check_indent;
}

pub fn readBlockHeader(self: *Lexer) void {
  std.debug.assert(self.state == .special_syntax);
  self.state = .after_blocks_colon;
}

/// block headers are aborted on the first error, to avoid parsing large
/// chunks of code as block header if it's not properly closed.
pub fn abortBlockHeader(self: *Lexer) void {
  self.state = if (self.level.special == .disabled) (
    .at_header
  ) else .special_syntax;
}