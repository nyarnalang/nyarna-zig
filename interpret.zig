const std = @import("std");
const data = @import("data");
const parse = @import("parse.zig");

pub const Errors = error {
  failed_to_interpret_node,
  referred_source_unavailable,
};

/// This is the interpreter's context as seen by the parser.
pub const Context = struct {
  /// Allocator used for AST nodes that will be discarded after interpretation
  /// has produced an expression.
  temp_nodes: std.heap.ArenaAllocator,
  /// Allocator used for expressions and AST nodes that can be accessed by other
  /// sources after interpretation has finished.
  source_content: std.heap.ArenaAllocator,

  /// Interprets the given node and returns an expression.
  /// immediate==true will use the temporary allocator and is expected to be
  /// immediately evaluated (i.e. used for keyword calls).
  /// immediate==false will use the source_content allocator and is expected to
  /// be used for expressions relevant in the interpretation result.
  pub fn interpret(input: *data.Node, immediate: bool) !*data.Expression {
    // TODO
    return Errors.failed_to_interpret_node;
  }

  /// Evaluates the given expression, which must be a call to a keyword that
  /// returns an AstNode. Can return .referred_source_unavailable, in which case
  /// current interpretation must pause and the referred source must be
  /// interpreted instead. Afterwards, interpretation can continue.
  pub fn evaluateToAstNode(expr: *data.Expression) !*data.Node {
    // TODO
    return referred_source_unavailable;
  }
};

/// This is the interpreter's interface as seen by a caller.
pub const Interpreter = struct {
  context: Context,
};