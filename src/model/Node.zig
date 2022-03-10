//! each type declared at top level is a Node type, safe for Data which is the
//! union of all possible node types.

const std = @import("std");
const locations = @import("locations.zig");
const model = @import("../model.zig");
const Expression = @import("Expression.zig");
const Symbol = @import("Symbol.zig");
const Type = model.Type;
const Value = @import("Value.zig");
const offset = @import("../helpers.zig").offset;

const Node = @This();

/// Assignment.
pub const Assign = struct {
  /// The node that is assigned to. If unresolved, is simply another node.
  /// Must be resolved to a 'path' into a variable, the path being a list of
  /// fields to descend into. An empty path assigns to the variable itself.
  ///
  /// transitioning from unresolved to resolved will generate a poison node if
  /// the unresolved node gets interpreted into something that is not a path
  /// into a variable.
  target: union(enum) {
    unresolved: *Node,
    resolved: struct {
      target: *Symbol.Variable,
      path: []usize,
      t: Type,
      pos: model.Position,
    },
  },
  /// rvalue node.
  replacement: *Node,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// A branching node. Branching works on enum types; the condition is to be
/// interpreted into an expression having an Enum type and the number of
/// branches must match the number of values of that Enum type.
///
/// Branches are generated by keywords such as \if.
pub const Branches = struct {
  condition: *Node,
  branches: []*Node,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const Concat = struct {
  items: []*Node,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Generated by definition syntax. Differs from a call to \Definition in that
/// it may contain unresolved subnodes.
pub const Definition = struct {
  name: *Node.Literal,
  root: ?model.Position,
  content: *Node,
  /// initially false, may be set to true during \declare processing
  public: bool,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Funcgen nodes define functions. Just like type generator nodes, they may
/// need multiple passes to be processed.
pub const Funcgen = struct {
  /// params are initially unresolved. Trying to interpret the Funcgen may
  /// successfully resolve the params while failing to interpret the body
  /// completely.
  params: locations.List(model.Function),
  params_ns: u15,
  returns: ?*Node,
  body: *Node,
  variables: *model.VariableContainer,
  /// set to true when generated by \method, false when generated by \func.
  /// \declare(\Type) will process this when transitioning params from
  /// .unresolved to .resolved and set it to false.
  ///
  /// It is an error when this is still true at the time the function is
  /// built, which means that \method was used outside of \declare(\Type).
  needs_this_inject: bool,
  /// used during fixpoint iteration for type inference.
  /// unused if `returns` is set.
  cur_returns: Type,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Import = struct {
  ns_index: u15,
  module_index: usize,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Literal = struct {
  kind: enum {text, space},
  content: []const u8,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
/// generated by location syntax. different from a call to \Location in that
/// it may contain unresolved subnodes.
pub const Location = struct {
  /// allocated separately to constrain size of Node.Data type.
  pub const Additionals = struct {
    primary: ?model.Position,
    varargs: ?model.Position,
    varmap: ?model.Position,
    mutable: ?model.Position,
    header: ?*Value.BlockHeader,
  };
  name: *Node.Literal,
  @"type": ?*Node,
  default: ?*Node,
  additionals: ?*Additionals,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const Paras = struct {
  pub const Item = struct {
    content: *Node,
    lf_after: usize
  };
  // lf_after of last item is ignored.
  items: []Item,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
/// An access chain whose base type is known and whose accessors have been
/// resolved.
pub const ResolvedAccess = struct {
  base: *Node,
  path: []const usize,
  last_name_pos: model.Position,
  ns: u15,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const ResolvedCall = struct {
  ns: u15,
  target: *Node,
  args: []*Node,
  sig: *const model.Signature,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const ResolvedSymref = struct {
  ns: u15,
  sym: *Symbol,
  name_pos: model.Position,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const UnresolvedAccess = struct {
  subject: *Node,
  id: []const u8,
  id_pos: model.Position,
  ns: u15,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const UnresolvedCall = struct {
  pub const ArgKind = union(enum) {
    named: []const u8,
    direct: []const u8,
    primary,
    position,

    pub inline fn isDirect(self: ArgKind) bool {
      return self == .direct or self == .primary;
    }
  };
  pub const ProtoArg = struct {
    kind: ArgKind,
    content: *Node,
    /// See doc of first_block_arg below.
    had_explicit_block_config: bool,
  };
  target: *Node,
  proto_args: []ProtoArg,
  /// This is used when a call's target is resolved *after* the arguments
  /// have been read in. The resolution checks whether any argument that was
  /// given as block and did not have an explicit block config would have
  /// gotten a default block config – which will then be reported as error.
  first_block_arg: usize,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};
pub const UnresolvedSymref = struct {
  ns: u15,
  name: []const u8,
  nschar_len: u3,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }

  pub inline fn namePos(self: *@This()) model.Position {
    return self.node().pos.trimFrontChar(self.nschar_len);
  }
};

/// collects the multiple arguments given to a varargs parameter.
pub const Varargs = struct {
  pub const Item = struct {
    direct: bool = false,
    node: *Node,
  };

  t: Type,
  content: std.ArrayListUnmanaged(Item) = .{},

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// special node for the sole purpose of setting a variable's type later.
/// variables must be established immediately so that references to their
/// symbol can be resolved before the symbol goes out of scope. However, the
/// type of a variable might not be available immediately if defined by its
/// initial expression (i.e. the initial expression cannot be interpreted
/// immediately). In that case, the variable's type is set to .every which
/// tells referrers that references to that variable mustn't be interpreted
/// yet. Interpreting the VarTypeSetter node will update the type of v with
/// the type of the interpreted node, and returns the result of interpreting
/// the node.
pub const VarTypeSetter = struct {
  v: *Symbol.Variable,
  content: *Node,

  pub inline fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Nodes in here are type generator nodes. They are created by prototype
/// functions (e.g. \List, \Concat, \Textual etc). They may need multiple
/// passes for interpretation since they can refer to each other (e.g. inside
/// of a \declare command).
///
/// Each generator that can refer to other types holds a `generated` value
/// that is set when the type has been created, but not yet finished, during
/// \declare resolution.
pub const tg = struct {
  pub const Concat = struct {
    inner: *Node,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Enum = struct {
    values: []*Node,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Float = struct {
    precision: *Node,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Intersection = struct {
    types: []Varargs.Item,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const List = struct {
    inner: *Node,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Map = struct {
    key: *Node,
    value: *Node,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Numeric = struct {
    min: ?*Node,
    max: ?*Node,
    decimals: ?*Node,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Optional = struct {
    inner: *Node,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Paragraphs = struct {
    inners: []*Node,
    auto: ?*Node,
    generated: ?*Type.Structural = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Record = struct {
    fields: locations.List(void),
    generated: ?*Type.Instantiated = null,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Textual = struct {
    categories: []*Node,
    include_chars: *Node,
    exclude_chars: *Node,
    pub inline fn node(self: *@This()) *Node {return Node.parent(self);}
  };
};

pub const Data = union(enum) {
  assign           : Assign,
  branches         : Branches,
  concat           : Concat,
  definition       : Definition,
  expression       : *Expression,
  funcgen          : Funcgen,
  gen_concat       : tg.Concat,
  gen_enum         : tg.Enum,
  gen_float        : tg.Float,
  gen_intersection : tg.Intersection,
  gen_list         : tg.List,
  gen_map          : tg.Map,
  gen_numeric      : tg.Numeric,
  gen_optional     : tg.Optional,
  gen_paragraphs   : tg.Paragraphs,
  gen_record       : tg.Record,
  gen_textual      : tg.Textual,
  import           : Import,
  literal          : Literal,
  location         : Location,
  paras            : Paras,
  resolved_access  : ResolvedAccess,
  resolved_call    : ResolvedCall,
  resolved_symref  : ResolvedSymref,
  unresolved_access: UnresolvedAccess,
  unresolved_call  : UnresolvedCall,
  unresolved_symref: UnresolvedSymref,
  varargs          : Varargs,
  vt_setter        : VarTypeSetter,
  poison,
  void,
};

pos: model.Position,
data: Data,

fn parent(it: anytype) *Node {
  const t = @typeInfo(@TypeOf(it)).Pointer.child;
  const addr = @ptrToInt(it) - switch (t) {
    Assign           => offset(Data, "assign"),
    Branches         => offset(Data, "branches"),
    Concat           => offset(Data, "concat"),
    Definition       => offset(Data, "definition"),
    *Expression      => offset(Data, "expression"),
    Funcgen          => offset(Data, "funcgen"),
    Import           => offset(Data, "import"),
    Literal          => offset(Data, "literal"),
    Location         => offset(Data, "location"),
    Paras            => offset(Data, "paras"),
    ResolvedAccess   => offset(Data, "resolved_access"),
    ResolvedCall     => offset(Data, "resolved_call"),
    ResolvedSymref   => offset(Data, "resolved_symref"),
    tg.Concat        => offset(Data, "gen_concat"),
    tg.Enum          => offset(Data, "gen_enum"),
    tg.Float         => offset(Data, "gen_float"),
    tg.Intersection  => offset(Data, "gen_intersection"),
    tg.List          => offset(Data, "gen_list"),
    tg.Map           => offset(Data, "gen_map"),
    tg.Numeric       => offset(Data, "gen_numeric"),
    tg.Optional      => offset(Data, "gen_optional"),
    tg.Paragraphs    => offset(Data, "gen_paragraphs"),
    tg.Record        => offset(Data, "gen_record"),
    tg.Textual       => offset(Data, "gen_textual"),
    UnresolvedAccess => offset(Data, "unresolved_access"),
    UnresolvedCall   => offset(Data, "unresolved_call"),
    UnresolvedSymref => offset(Data, "unresolved_symref"),
    Varargs          => offset(Data, "varargs"),
    VarTypeSetter    => offset(Data, "vt_setter"),
    else => unreachable
  };
  return @fieldParentPtr(Node, "data", @intToPtr(*Data, addr));
}

pub fn lastIdPos(self: *Node) model.Position {
  return switch (self.data) {
    .resolved_access => |*racc| racc.last_name_pos,
    .resolved_symref => |*rsym| rsym.name_pos,
    .unresolved_access => |*uacc| uacc.id_pos,
    .unresolved_symref => |*usym| usym.namePos(),
    else => model.Position{
      .source = self.pos.source,
      .start = self.pos.end,
      .end = self.pos.end,
    },
  };
}