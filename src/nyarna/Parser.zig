//! The parser creates AST nodes.
//! Whenever an AST node is created, the parser checks whether it needs to be
//! evaluated immediately, and if so, asks the interpreter to do so, which will
//! yield the replacement for the original node.

const Lexer       = @import("Parser/Lexer.zig");
const highlight   = @import("highlight.zig");
const nyarna      = @import("../nyarna.zig");

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
impl: @import("Parser/Impl.zig"),
/// whether current state has been emitted. used for the highlighting interface.
emitted: bool = true,

pub fn init() @This() {
  return @This(){.impl = .{
    .config = null,
    .levels = .{},
    .ns_mapping_stack = .{},
    .lexer = undefined,
    .state = .start,
    .cur = undefined,
    .cur_start = undefined,
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
  self.impl.advance();
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
  while (!(try self.impl.doParse())) {}
  return self.impl.levels.items[0].finalize(&self.impl);
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