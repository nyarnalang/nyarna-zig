//! The parser creates AST nodes.
//! Whenever an AST node is created, the parser checks whether it needs to be
//! evaluated immediately, and if so, asks the interpreter to do so, which will
//! yield the replacement for the original node.

const std = @import("std");

const Impl        = @import("Parser/Impl.zig");
const Lexer       = @import("Parser/Lexer.zig");
const highlight   = @import("highlight.zig");
const nyarna      = @import("../nyarna.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

pub const LiteralNumber = @import("Parser/LiteralNumber.zig");
pub const Mapper        = @import("Parser/Mapper.zig");

/// The parser can return one of these if outside action is required before
/// resuming parsing.
pub const UnwindReason = error {
  /// emitted when an \import is encountered, but the referred module has not
  /// been processed far enough.
  ///
  /// if arguments are given to the import, the referred module needs only to
  /// be processed up until its parameter declaration.
  ///
  /// if arguments have been processed or none have been given, the referred
  /// module needs tob e fully loaded.
  referred_module_unavailable,
  /// emitted when a module's options declaration has been encountered. Caller
  /// may inspect declared parameters, push available arguments, then resume
  /// parsing.
  ///
  /// Caller is not required to check whether all parameters get an argument or
  /// whether pushed arguments can be bound. This will be checked and handled by
  /// the parser, errors will be logged.
  encountered_options,
};

pub const Error = nyarna.Error || UnwindReason;

/// parser implementation. mustn't be accessed from outside.
impl: Impl,
/// whether current state has been emitted. used for the highlighting interface.
emitted: bool = true,

pub fn init() @This() {
  return @This(){.impl = .{
    .block_header     = undefined,
    .levels           = .{},
    .ns_mapping_stack = .{},
    .lexer            = undefined,
    .state            = .start,
    .text             = undefined,
    .special          = undefined,
  }};
}

/// Start parsing the given source. Must be called after init().
pub fn start(
  self: *@This(),
  intpr: *Interpreter,
  source: *model.Source,
  fullast: bool,
) !void {
  self.impl.lexer = try Lexer.init(intpr, source);
  try self.impl.procRootStart(fullast);
}

/// Attempts to build the syntax tree. Must have called start() before.
/// When .referred_module_unavailable or .encountered_options is returned,
/// parsing can be continued by calling build() again later. Other errors are
/// not recoverable.
///
/// .referred_module_unavailable requires the referred module to be loaded
/// before continuing. .encountered_options requires pushing option values
/// and finalizing options before continuing.
///
/// General parsing errors are not returned as errors of this function.
/// Instead, they are handed to the loader's errors.Handler. To check whether
/// errors have occurred, check for an increase of the handler's error_count.
pub fn build(self: *@This()) Error!*model.Node {
  while (true) {
    const accepts_comment = self.impl.state == .textual;
    const cur = advance(&self.impl, accepts_comment);
    if ((try self.impl.push(cur))) break;
  }
  std.debug.assert(self.impl.levels.items.len == 1);
  const ret = try self.impl.levels.items[0].finalize(&self.impl);
  const fmt = @import("fmt.zig").IndentingFormatter(
    *model.Node, std.fs.File.Writer).init(ret, 0, self.impl.intpr().ctx.data);
  std.debug.print("{}\n", .{fmt});
  return ret;
}

pub const SyntaxItem = struct {
  kind: enum { text, comment, escape, keyword, symref, special, tag},
  length: usize,
};

/// Interface for syntax highlighting. Returns the next item, or null if the
/// parser has finished. `from` is an index into the source and tells the
/// highlighter where the next item should start. This is used both for emitting
/// text between control structures, and to ignore a certain part of the input
/// at the beginning.
pub fn next(self: *@This(), from: usize) !?SyntaxItem {
  _ = self;
  _ = from;
  return null;
}

/// retrieves the next valid token from the lexer.
/// emits errors for any invalid token along the way.
fn advance(impl: *Impl, comment: bool) model.TokenAt {
  while (true) {
    const at = impl.lexer.recent_end;
    (switch (impl.lexer.next() catch blk: {
      const first = at;
      const token = while (true) {
        break impl.lexer.next() catch continue;
      } else unreachable;
      impl.logger().InvalidUtf8Encoding(impl.lexer.walker.posFrom(first));
      break :blk token;
    }) {
      // the following errors are not handled here since they indicate
      // structure:
      //   missing_block_name_sep (ends block name)
      //   wrong_call_id, skipping_call_id (end a call)
      //
      .illegal_code_point => errors.Handler.IllegalCodePoint,
      .illegal_opening_parenthesis =>
        errors.Handler.IllegalOpeningParenthesis,
      .illegal_blocks_start_in_args =>
        errors.Handler.IllegalBlocksStartInArgs,
      .illegal_command_char      => errors.Handler.IllegalCommandChar,
      .illegal_characters        => errors.Handler.IllegalCharacters,
      .mixed_indentation         => errors.Handler.MixedIndentation,
      .illegal_indentation       => errors.Handler.IllegalIndentation,
      .illegal_content_at_header => errors.Handler.IllegalContentAtHeader,
      .invalid_end_command       => errors.Handler.InvalidEndCommand,
      .comment => if (comment) (
        return .{.start = at, .token = .comment}
      ) else continue,
      else => |t| {
        return .{.start = at, .token = t};
      }
    })(impl.logger(), impl.lexer.walker.posFrom(at));
  }
}

/// retrieves the next token from the lexer. true iff that token is valid.
/// if false is returned, self.cur is to be considered undefined.
/// NOT SURE IF STILL NEEDED
pub fn getNext(self: *@This()) bool {
  self.cur_start = self.lexer.recent_end;
  (switch (self.lexer.next() catch {
    self.logger().InvalidUtf8Encoding(
      self.lexer.walker.posFrom(self.cur_start));
    return false;
  }) {
    .missing_block_name_sep       => errors.Handler.MissingBlockNameEnd,
    .illegal_code_point           => errors.Handler.IllegalCodePoint,
    .illegal_opening_parenthesis  => errors.Handler.IllegalOpeningParenthesis,
    .illegal_blocks_start_in_args => errors.Handler.IllegalBlocksStartInArgs,
    .illegal_command_char         => errors.Handler.IllegalCommandChar,
    .illegal_characters           => errors.Handler.IllegalCharacters,
    .mixed_indentation            => errors.Handler.MixedIndentation,
    .illegal_indentation          => errors.Handler.IllegalIndentation,
    .illegal_content_at_header    => errors.Handler.IllegalContentAtHeader,
    .invalid_end_command          => errors.Handler.InvalidEndCommand,
    .no_block_call_id => unreachable,
    .wrong_call_id    => unreachable,
    .skipping_call_id => unreachable,
    else => |t| {
      if (@enumToInt(t) > @enumToInt(model.Token.skipping_call_id))
        unreachable;
      self.cur = t;
      return true;
    }
  })(self.logger(), self.lexer.walker.posFrom(self.cur_start));
  return false;
}