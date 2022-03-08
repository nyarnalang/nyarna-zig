const model = @import("../model.zig");
const Value = @import("Value.zig");
const Node = @import("Node.zig");
const Symbol = @import("Symbol.zig");
const Type = model.Type;
const offset = @import("../helpers.zig").offset;

const Expression = @This();

/// a call to a function or type constructor.
pub const Call = struct {
  /// only set for calls to keywords, for which it may be relevant.
  ns: u15,
  target: *Expression,
  exprs: []*Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// assignment to a variable or one of its inner values
pub const Assignment = struct {
  target: *Symbol.Variable,
  /// list of indexes that identify which part of the variable is to be
  /// assigned.
  path: []const usize,
  expr: *Expression,
};

/// retrieval of the value of a substructure
pub const Access = struct {
  subject: *Expression,
  /// list of indexes that identify which part of the value is to be
  /// retrieved.
  path: []const usize,
};

/// retrieval of a variable's value
pub const VarRetrieval = struct {
  variable: *Symbol.Variable,
};

/// concatenation
pub const Concatenation = []*Expression;

// if or switch expression
pub const Branches = struct {
  condition: *Expression,
  branches: []*Expression,
};

/// an ast subtree
pub const Ast = struct {
  root: *Node,
};

/// part of a Paragraphs expression.
pub const Paragraph = struct {
  content: *Expression,
  lf_after: usize,
};

pub const Paragraphs = []Paragraph;

/// used to enclose arguments given to a varargs parameter.
/// expected_type will be a List(T).
pub const Varargs = struct {
  pub const Item = struct {
    direct: bool,
    expr: *Expression,
  };

  items: []Item,
};

pub const Data = union(enum) {
  access: Access,
  assignment: Assignment,
  branches: Branches,
  call: Call,
  concatenation: Concatenation,
  paragraphs: Paragraphs,
  var_retrieval: VarRetrieval,
  value: *Value,
  varargs: Varargs,
  poison, void,
};

pos: model.Position,
data: Data,
/// May be imposed upon it by its context [8.3]. Evaluating this expression
/// will yield a value with a Type in E_{expected_type}.
expected_type: Type,

fn parent(it: anytype) *Expression {
  const t = @typeInfo(@TypeOf(it)).Pointer.child;
  const addr = @ptrToInt(it) - switch (t) {
    Access        => offset(Data, "access"),
    Assignment    => offset(Data, "assignment"),
    Branches      => offset(Data, "branches"),
    Call          => offset(Data, "call"),
    Concatenation => offset(Data, "concatenation"),
    Paragraphs    => offset(Data, "paragraphs"),
    VarRetrieval  => offset(Data, "var_retrieval"),
    Varargs       => offset(Data, "varargs"),
    else => unreachable
  };
  return @fieldParentPtr(Expression, "data", @intToPtr(*Data, addr));
}