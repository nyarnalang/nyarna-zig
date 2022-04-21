const model = @import("../model.zig");
const Value = @import("Value.zig");
const Node = @import("Node.zig");
const Symbol = @import("Symbol.zig");
const Type = model.Type;
const offset = @import("../helpers.zig").offset;

const Expression = @This();

/// retrieval of the value of a substructure
pub const Access = struct {
  subject: *Expression,
  /// list of indexes that identify which part of the value is to be
  /// retrieved.
  path: []const usize,

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
  rexpr: *Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// an ast subtree
pub const Ast = struct {
  root: *Node,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

// if or switch expression
pub const Branches = struct {
  condition: *Expression,
  branches: []*Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

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

pub const Conversion = struct {
  inner: *Expression,
  target_type: model.Type,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// concatenation
pub const Concatenation = []*Expression;

/// expression that generates a Location. This is necessary for locations of
/// prototype functions that may contain references to the prototype's params.
pub const Location = struct {
  name: *Expression,
  @"type": ?*Expression,
  default: ?*Expression,
  additionals: ?*model.Node.Location.Additionals,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// part of a Sequence expression.
pub const Paragraph = struct {
  content: *Expression,
  lf_after: usize,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const Sequence = []Paragraph;

/// used to enclose arguments given to a varargs parameter.
/// expected_type will be a List(T).
pub const Varargs = struct {
  pub const Item = struct {
    direct: bool,
    expr: *Expression,
  };

  items: []Item,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// retrieval of a variable's value
pub const VarRetrieval = struct {
  variable: *Symbol.Variable,

  pub inline fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const tg = struct {
  pub const Concat = struct {
    inner: *Expression,

    pub inline fn expr(self: *@This()) *Expression {
      return Expression.parent(self);
    }
  };

  pub const List = struct {
    inner: *Expression,

    pub inline fn expr(self: *@This()) *Expression {
      return Expression.parent(self);
    }
  };

  pub const Optional = struct {
    inner: *Expression,

    pub inline fn expr(self: *@This()) *Expression {
      return Expression.parent(self);
    }
  };

  pub const Sequence = struct {
    direct: ?*Expression,
    inner : []Varargs.Item,
    auto  : ?*Expression,

    pub inline fn expr(self: *@This()) *Expression {
      return Expression.parent(self);
    }
  };
};

pub const Data = union(enum) {
  access       : Access,
  assignment   : Assignment,
  branches     : Branches,
  call         : Call,
  concatenation: Concatenation,
  conversion   : Conversion,
  location     : Location,
  sequence     : Sequence,
  tg_concat    : tg.Concat,
  tg_list      : tg.List,
  tg_optional  : tg.Optional,
  tg_sequence  : tg.Sequence,
  var_retrieval: VarRetrieval,
  value        : *Value,
  varargs      : Varargs,
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
    Location      => offset(Data, "location"),
    Sequence      => offset(Data, "sequence"),
    tg.Concat     => offset(Data, "tg_concat"),
    tg.List       => offset(Data, "tg_list"),
    tg.Optional   => offset(Data, "tg_optional"),
    tg.Sequence   => offset(Data, "sequence"),
    VarRetrieval  => offset(Data, "var_retrieval"),
    Varargs       => offset(Data, "varargs"),
    else => unreachable
  };
  return @fieldParentPtr(Expression, "data", @intToPtr(*Data, addr));
}