//! The parser creates AST nodes.
//! Whenever an AST node is created, the parser checks whether it needs to be
//! evaluated immediately, and if so, asks the interpreter to do so, which will
//! yield the replacement for the original node.

const Interpreter = @import("interpret.zig").Interpreter;
const Lexer       = @import("Parser/Lexer.zig");
const nyarna      = @import("../nyarna.zig");
const model       = @import("model.zig");

pub const LiteralNumber = @import("Parser/LiteralNumber.zig");

/// Mapper is the interface for mapping call arguments to parameters.
/// This is a multi-stage process for each argument:
///
///  * first, the argument is mapped via `map()`. For block arguments, this must
///    occur before the argument content is read so that block config can be
///    applied. Unmappable arguments must also return a valid cursor.
///  * `map()` returns a Cursor that can be used to query implicit block config
///    of the target parameter via `config()`.
///  * Similarly, `paramType()` can be used to query the type of the target
///    parameter. This may return `null` for unmappable arguments.
///  * After the content of the argument has been read, `push()` is to be called
///    to finalize the argument by pushing its content.
///
/// When all arguments have been pushed, `finalize()` is to be called to
/// generate the node resulting from the call.
pub const Mapper = @import("Parser/Mapper.zig");

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
  /// emitted when a module's parameter declaration has been encountered. Caller
  /// may inspect declared parameters, push available arguments, then resume
  /// parsing.
  ///
  /// Caller is not required to check whether all parameters get an argument or
  /// whether pushed arguments can be bound. This will be checked and handled by
  /// the parser, errors will be logged.
  encountered_parameters,
};

pub const Error = nyarna.Error || UnwindReason;

/// parser implementation. mustn't be accessed from outside.
impl: @import("Parser/Impl.zig"),

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

/// parse context.input. If it returns .referred_source_unavailable, parsing
/// may be resumed via resumeParse() after the referred source has been
/// loaded. Other returned errors are not recoverable.
///
/// Errors in the given input are not returned as errors of this function.
/// Instead, they are handed to the loader's errors.Handler. To check whether
/// errors have occurred, check for increase of the handler's error_count.
pub fn parseSource(
  self   : *@This(),
  context: *Interpreter,
  fullast: bool,
) Error!*model.Node {
  self.impl.lexer = try Lexer.init(context);
  self.impl.advance();
  return self.impl.doParse(fullast);
}

/// continue parsing. Precondition: parseSource() or resumeParse() have
/// returned with an UnwindReason previously on the given parser, and have
/// never returned a *model.Node.
///
/// Apart from the precondition, this function has the same semantics as
/// parseSource(), including that it may return .referred_source_unavailable.
pub fn resumeParse(self: *@This()) Error!*model.Node {
  // when resuming, the fullast value is irrelevant since it is only inspected
  // when encountering the first non-space token in the file – which will
  // always be before parsing is interrupted.
  return self.impl.doParse(undefined);
}