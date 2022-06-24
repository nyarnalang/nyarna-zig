const std = @import("std");

const model = @import("../model.zig");

const Node   = model.Node;
const Symbol = model.Symbol;
const Type   = model.Type;
const Value  = model.Value;

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
  path : []const usize,
  rexpr: *Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

// if or switch expression
pub const Branches = struct {
  condition: *Expression,
  branches : []*Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// a call to a function or type constructor.
pub const Call = struct {
  /// only set for calls to keywords, for which it may be relevant.
  ns    : u15,
  target: *Expression,
  exprs : []*Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const Conversion = struct {
  inner      : *Expression,
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
  name       : *Expression,
  @"type"    : ?*Expression,
  default    : ?*Expression,
  additionals: ?*model.Node.Location.Additionals,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const Output = struct {
  name  : *Value.TextScalar,
  schema: ?*Value.Schema,
  body  : *Expression,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

/// A call to \map
pub const Map = struct {
  input: *Expression,
  func : ?*Expression,
  // expected_type defines whether to collect into List, Concat or Seq.

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const Match = struct {
  pub const Body = struct {
    expr     : *Expression,
    container: *model.VariableContainer,
    /// true if a block capture exists.
    has_var  : bool,
  };

  pub const HashMap = std.HashMapUnmanaged(
    model.SpecType, Body, model.SpecType.HashContext,
    std.hash_map.default_max_load_percentage
  );

  subject: *Expression,
  cases  : HashMap,

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
    expr  : *Expression,
  };

  items: []Item,

  pub fn expr(self: *@This()) *Expression {
    return Expression.parent(self);
  }
};

pub const Varmap = struct {
  pub const Item = struct {
    key: union(enum) {
      expr: *Expression,
      direct,
    },
    value: *Expression,
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

  pub const HashMap = struct {
    key  : *Expression,
    value: *Expression,

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
  map          : Map,
  match        : Match,
  output       : Output,
  sequence     : Sequence,
  tg_concat    : tg.Concat,
  tg_list      : tg.List,
  tg_map       : tg.HashMap,
  tg_optional  : tg.Optional,
  tg_sequence  : tg.Sequence,
  var_retrieval: VarRetrieval,
  value        : *Value,
  varargs      : Varargs,
  varmap       : Varmap,
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
    Map           => offset(Data, "map"),
    Match         => offset(Data, "match"),
    Output        => offset(Data, "output"),
    Sequence      => offset(Data, "sequence"),
    tg.Concat     => offset(Data, "tg_concat"),
    tg.HashMap    => offset(Data, "tg_map"),
    tg.List       => offset(Data, "tg_list"),
    tg.Optional   => offset(Data, "tg_optional"),
    tg.Sequence   => offset(Data, "sequence"),
    VarRetrieval  => offset(Data, "var_retrieval"),
    Varargs       => offset(Data, "varargs"),
    Varmap        => offset(Data, "varmap"),
    else => unreachable
  };
  return @fieldParentPtr(Expression, "data", @intToPtr(*Data, addr));
}