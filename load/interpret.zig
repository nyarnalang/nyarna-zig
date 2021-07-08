const std = @import("std");
const data = @import("data");
const parse = @import("parse.zig");

pub const Errors = error {
  failed_to_interpret_node,
  referred_source_unavailable,
};

/// The Context is a view of the loader for the various processing steps
/// (lexer, parser, interpreter). It effectively implements the interpreter
/// since the parser can initiate interpretation of nodes.
pub const Context = struct {
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer uses this to check whether a character is a command
  /// character; the namespace mapping is relevant later for the interpreter.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u16),
  /// Allocator used for AST nodes that will be discarded after interpretation
  /// has produced an expression.
  temp_nodes: std.heap.ArenaAllocator,
  /// Allocator used for expressions and AST nodes that can be accessed by other
  /// sources after interpretation has finished.
  source_content: std.heap.ArenaAllocator,

  pub fn init(allocator: *std.mem.Allocator) !Context {
    var ret = Context{
      .temp_nodes = std.heap.ArenaAllocator.init(allocator),
      .source_content = std.heap.ArenaAllocator.init(allocator),
      .command_characters = .{},
    };
    errdefer ret.deinit().deinit();
    try ret.command_characters.put(&ret.temp_nodes.allocator, '\\', 0);
    return ret;
  }

  /// returns the allocator used for externally available source content.
  /// that allocator must be used to unload the generated content.
  pub fn deinit(c: *Context) std.heap.ArenaAllocator {
    c.temp_nodes.deinit();
    return c.source_content;
  }

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

  pub fn resolveSymbol(ns: u16, sym: []const u8) *data.Node {
    // TODO
    unreachable;
  }
};