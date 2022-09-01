//! Node is a node in the AST. Nodes are interpreted into Expressions by the
//! interpreter. A Node can transition through multiple states before being
//! interpreted, e.g. an UnresolvedCall may become a ResolvedCall before being
//! fully interpreted. State transitions happen when information about the node
//! is requested (a query for the node's expression is such a request, among
//! others) and enough information is available for the node to make the
//! transition.

const std = @import("std");

const fmt     = @import("../fmt.zig");
const Globals = @import("../Globals.zig");
const model   = @import("../model.zig");

const Expression = model.Expression;
const locations  = model.locations;
const Symbol     = model.Symbol;
const Type       = model.Type;
const Value      = model.Value;

const offset = @import("../helpers.zig").offset;

const Node = @This();

/// Assignment Node.
pub const Assign = struct {
  pub const PathItem = union(enum) {
    field: struct {
      t    : *model.Type.Record,
      index: usize,
    },
    subscript: *Node,
  };
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
      path  : []PathItem,
      spec  : model.SpecType,
      pos   : model.Position,
    },
  },
  /// rvalue node.
  replacement: *Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// node generated by \backend. Will be processed into an actual backend of a
/// schema.
pub const Backend = struct {
  vars : ?*Node,
  funcs: []*Definition,
  body : ?*Value.Ast,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Node that generates builtin and keyword definitions.
/// Must only be used in context of \declare so that the interpreter can map
/// the builtin to a provided internal function via the builtin's name.
pub const BuiltinGen = struct {
  params : locations.List(void),
  returns: union(enum) {
    node: *Node,
    expr: *Expression,
  },

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Capture nodes are generated from given capture variables.
/// They wrap the actual content.
pub const Capture = struct {
  /// at least one
  vars: []Value.Ast.VarDef,
  /// block's content
  content: *Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Concat = struct {
  items: []*Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Generated by definition syntax. Differs from a call to \Definition in that
/// it may contain unresolved subnodes.
pub const Definition = struct {
  name   : *Node.Literal,
  content: *Node,
  /// position of `|=` if any.
  merge: ?model.Position,
  /// initially false, may be set to true during \declare processing
  public: bool,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const For = struct {
  input    : *Node,
  collector: ?*Node,
  body     : *Node,
  captures : []Value.Ast.VarDef,
  variables: *model.VariableContainer,
  /// whether variables have been created inside the body
  gen_vars : bool = false,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Funcgen nodes define functions. Just like type generator nodes, they may
/// need multiple passes to be processed.
pub const Funcgen = struct {
  /// params are initially unresolved. Trying to interpret the Funcgen may
  /// successfully resolve the params while failing to interpret the body
  /// completely.
  params   : locations.List(model.Function),
  params_ns: u15,
  returns  : ?*Node,
  body     : *Node,
  variables: *model.VariableContainer,
  /// used during fixpoint iteration for type inference.
  /// unused if `returns` is set.
  cur_returns: Type,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Highlighter = struct {
  pub const Renderer = struct {
    name    : *Node.Literal,
    content : *Node,
    variable: ?Value.Ast.VarDef,
  };

  syntax   : *model.Node,
  renderers: []Renderer,
  /// stores the return type if it has already been calculated
  ret_type : ?model.Type = null,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

// Generated from \if calls. `condition` must be interpreted into an expression
// having either an enum or an optional type. `then` may have a capture variable
// but only if `condition` is optional.
pub const If = struct {
  condition      : *Node,
  then           : *Value.Ast,
  @"else"        : ?*Node,
  /// used during interpretation to store the variable created from a capture in
  /// `then`.
  variable_state : union(enum) {
    generated  : ?*Symbol.Variable,
    unprocessed, none
  } = .unprocessed,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Import = struct {
  ns_index    : u15,
  module_index: usize,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Literal = struct {
  pub const Kind = enum {text, space};

  kind   : Kind,
  content: []const u8,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// generated by location syntax. different from a call to \Location in that
/// it may contain unresolved subnodes.
pub const Location = struct {
  /// allocated separately to constrain size of Node.Data type, and because this
  /// is carried over into the Location Expression and thus must be allocated
  /// globally.
  pub const Additionals = struct {
    primary: ?model.Position,
    varargs: ?model.Position,
    varmap : ?model.Position,
    borrow : ?model.Position,
    header : ?*Value.BlockHeader,

    pub fn formatter(
      self: *const Additionals,
    ) std.fmt.Formatter(fmt.formatAdditionals) {
      return .{.data = self};
    }
  };
  name       : *Node,
  @"type"    : ?*Node,
  default    : ?*Node,
  additionals: ?*Additionals,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// Call to \map. Not related to HashMaps.
pub const Map = struct {
  input    : *Node,
  func     : ?*Node,
  collector: ?*Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// this node if both for \match and \matcher, subject being null for the
/// latter.
pub const Match = struct {
  pub const Case = struct {
    t        : *Node,
    content  : *Value.Ast,
    /// if given, is initially def, which will transition to sym. sym will not
    /// have its container set yet. .none if no capture was given for the block.
    variable : union(enum) {
      def: Value.Ast.VarDef,
      sym: *model.Symbol.Variable,
      none
    },
  };

  subject: *Node,
  cases  : []Case,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Matcher = struct {
  body: *Match,
  /// variable used as subject in body
  variable: *Symbol.Variable,
  /// container in which the variable has been declared
  container: *model.VariableContainer,
  /// used during fixpoint iteration for type inference.
  cur_returns: Type,
  /// pregenerated function whose body has not yet been set.
  /// used during declare resolution.
  pregen: ?*model.Function = null,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Output = struct {
  name  : *Node,
  schema: ?*Node,
  body  : *Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// An access chain whose base type is known and whose accessors have been
/// resolved.
pub const ResolvedAccess = struct {
  base         : *Node,
  path         : []const Assign.PathItem,
  last_name_pos: model.Position,
  ns           : u15,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const ResolvedCall = struct {
  ns    : u15,
  target: *Node,
  args  : []*Node,
  sig   : *const model.Signature,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const ResolvedSymref = struct {
  ns      : u15,
  sym     : *Symbol,
  name_pos: model.Position,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

/// RootDef is a node created from \library, \fragment and \standalone keywords.
/// it postpones the interpretation of parameters and the root type / schema
/// until after any options have been fed into the module loader. Generating a
/// RootDef causes the current module to stop parsing if at least one option is
/// specified, and will query the importing location for option values.
pub const RootDef = struct {
  kind  : enum { library, fragment, standalone },
  root  : ?*Node,
  params: ?*Node,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Seq = struct {
  pub const Item = struct {
    content : *Node,
    lf_after: usize
  };
  // lf_after of last item is ignored.
  items: []Item,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const UnresolvedAccess = struct {
  subject: *Node,
  name   : *Node,
  ns     : u15,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const UnresolvedCall = struct {
  pub const ArgKind = union(enum) {
    named    : []const u8,
    direct   : []const u8,
    name_expr: *Node,
    primary,
    position,

    pub fn isDirect(self: ArgKind) bool {
      return self == .direct or self == .primary;
    }
  };
  pub const ProtoArg = struct {
    kind   : ArgKind,
    content: *Node,
    /// See doc of first_block_arg below.
    had_explicit_block_config: bool,
  };
  target    : *Node,
  proto_args: []ProtoArg,
  /// This is used when a call's target is resolved *after* the arguments
  /// have been read in. The resolution checks whether any argument that was
  /// given as block and did not have an explicit block config would have
  /// gotten a default block config – which will then be reported as error.
  first_block_arg: usize,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const UnresolvedSymref = struct {
  ns        : u15,
  name      : []const u8,
  nschar_len: u3,

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }

  pub fn namePos(self: *@This()) model.Position {
    return self.node().pos.trimFrontChar(self.nschar_len);
  }
};

/// collects the multiple arguments given to a varargs parameter.
pub const Varargs = struct {
  pub const Item = struct {
    direct: bool = false,
    node  : *Node,
  };

  /// position at which the type for this varargs node has been specified.
  spec_pos: model.Position,
  t       : *Type.List,
  content : std.ArrayListUnmanaged(Item) = .{},

  pub fn node(self: *@This()) *Node {
    return Node.parent(self);
  }
};

pub const Varmap = struct {
  pub const Item = struct {
    key: union(enum) {
      node: *Node,
      direct,
    },
    value: *Node,
  };

  /// position at which the type for this varmap node has been specified.
  spec_pos: model.Position,
  t       : *Type.HashMap,
  content : std.ArrayListUnmanaged(Item) = .{},

  pub fn node(self: *@This()) *Node {
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

  pub fn node(self: *@This()) *Node {
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
    inner    : *Node,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Enum = struct {
    values: []Node.Varargs.Item,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const HashMap = struct {
    key      : *Node,
    value    : *Node,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Intersection = struct {
    types    : []Varargs.Item,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const List = struct {
    inner    : *Node,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Numeric = struct {
    backend : *Node,
    min     : ?*Node,
    max     : ?*Node,
    suffixes: *Value.HashMap,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Optional = struct {
    inner    : *Node,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Sequence = struct {
    direct   : ?*Node,
    inner    : []Node.Varargs.Item,
    auto     : ?*Node,
    generated: ?*Type.Structural = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Prototype = struct {
    params     : locations.List(void),
    constructor: ?*Node,
    funcs      : ?*Node,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Record = struct {
    embed    : []Node.Varargs.Item,
    abstract : ?*Node,
    fields   : locations.List(void),
    generated: ?*Type.Named = null,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Textual = struct {
    categories   : []Varargs.Item,
    include_chars: ?*Node,
    exclude_chars: ?*Node,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
  pub const Unique = struct {
    constr_params: ?*Node,
    /// used during declare resolution, since the type is first generated and
    /// later the constructor is built. This field stores the built type so that
    /// the constructor knows its return type.
    generated: Type = undefined,
    pub fn node(self: *@This()) *Node {return Node.parent(self);}
  };
};

pub const Data = union(enum) {
  assign           : Assign,
  backend          : Backend,
  builtingen       : BuiltinGen,
  capture          : Capture,
  concat           : Concat,
  definition       : Definition,
  expression       : *Expression,
  @"for"           : For,
  funcgen          : Funcgen,
  gen_concat       : tg.Concat,
  gen_enum         : tg.Enum,
  gen_intersection : tg.Intersection,
  gen_list         : tg.List,
  gen_map          : tg.HashMap,
  gen_numeric      : tg.Numeric,
  gen_optional     : tg.Optional,
  gen_sequence     : tg.Sequence,
  gen_prototype    : tg.Prototype,
  gen_record       : tg.Record,
  gen_textual      : tg.Textual,
  gen_unique       : tg.Unique,
  highlighter      : Highlighter,
  @"if"            : If,
  import           : Import,
  literal          : Literal,
  location         : Location,
  map              : Map,
  match            : Match,
  matcher          : Matcher,
  output           : Output,
  resolved_access  : ResolvedAccess,
  resolved_call    : ResolvedCall,
  resolved_symref  : ResolvedSymref,
  root_def         : RootDef,
  seq              : Seq,
  unresolved_access: UnresolvedAccess,
  unresolved_call  : UnresolvedCall,
  unresolved_symref: UnresolvedSymref,
  varargs          : Varargs,
  varmap           : Varmap,
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
    Backend          => offset(Data, "backend"),
    BuiltinGen       => offset(Data, "builtingen"),
    Capture          => offset(Data, "capture"),
    Concat           => offset(Data, "concat"),
    Definition       => offset(Data, "definition"),
    *Expression      => offset(Data, "expression"),
    For              => offset(Data, "for"),
    Funcgen          => offset(Data, "funcgen"),
    Highlighter      => offset(Data, "highlighter"),
    If               => offset(Data, "if"),
    Import           => offset(Data, "import"),
    Literal          => offset(Data, "literal"),
    Location         => offset(Data, "location"),
    Map              => offset(Data, "map"),
    Match            => offset(Data, "match"),
    Matcher          => offset(Data, "matcher"),
    Output           => offset(Data, "output"),
    ResolvedAccess   => offset(Data, "resolved_access"),
    ResolvedCall     => offset(Data, "resolved_call"),
    ResolvedSymref   => offset(Data, "resolved_symref"),
    RootDef          => offset(Data, "root_def"),
    Seq              => offset(Data, "seq"),
    tg.Concat        => offset(Data, "gen_concat"),
    tg.Enum          => offset(Data, "gen_enum"),
    tg.Intersection  => offset(Data, "gen_intersection"),
    tg.List          => offset(Data, "gen_list"),
    tg.HashMap       => offset(Data, "gen_map"),
    tg.Numeric       => offset(Data, "gen_numeric"),
    tg.Optional      => offset(Data, "gen_optional"),
    tg.Sequence      => offset(Data, "gen_sequence"),
    tg.Prototype     => offset(Data, "gen_prototype"),
    tg.Record        => offset(Data, "gen_record"),
    tg.Textual       => offset(Data, "gen_textual"),
    tg.Unique        => offset(Data, "gen_unique"),
    UnresolvedAccess => offset(Data, "unresolved_access"),
    UnresolvedCall   => offset(Data, "unresolved_call"),
    UnresolvedSymref => offset(Data, "unresolved_symref"),
    Varargs          => offset(Data, "varargs"),
    Varmap           => offset(Data, "varmap"),
    VarTypeSetter    => offset(Data, "vt_setter"),
    else => unreachable
  };
  return @fieldParentPtr(Node, "data", @intToPtr(*Data, addr));
}

pub fn lastIdPos(self: *Node) model.Position {
  return switch (self.data) {
    .resolved_access   => |*racc| racc.last_name_pos,
    .resolved_symref   => |*rsym| rsym.name_pos,
    .unresolved_access => |*uacc| uacc.name.pos,
    .unresolved_symref => |*usym| usym.namePos(),
    else => model.Position{
      .source = self.pos.source,
      .start  = self.pos.end,
      .end    = self.pos.end,
    },
  };
}

pub fn formatter(
  self: *Node,
  data: *Globals,
) std.fmt.Formatter(fmt.IndentingFormatter(*Node).format) {
  return .{.data = .{.payload = self, .depth = 0, .data = data}};
}