const std = @import("std");
const unicode = @import("load/unicode.zig");
const nyarna = @import("nyarna.zig");

/// an item on the stack
pub const StackItem = union {
  /// a value on the stack
  value: *Value,
  /// reference to a stackframe. this is the header of a stackframe, where
  /// the entity owning this frame stores its previous frame.
  frame_ref: ?[*]StackItem
};


/// A cursor inside a source file
pub const Cursor = struct {
  /// The line of the position, 1-based.
  at_line: usize,
  /// The column in front of which the cursor is positioned, 1-based.
  before_column: usize,
  /// Number of bytes in front of this position.
  byte_offset: usize,

  pub fn unknown() Cursor {
    return .{.at_line = 0, .before_column = 0, .byte_offset = 0};
  }
};

/// Describes the origin of a construct. Usually start and end cursor in a
/// source file, but can also come from command line parameters.
pub const Position = struct {
  source: *const Source.Descriptor,
  start: Cursor,
  end: Cursor,

  const IntrinsicSource = Source.Descriptor{
    .name = "<intrinsic>",
    .locator = ".std.intrinsic",
    .argument = false
  };

  /// Creates a new position starting at the start of left and ending at the end
  /// of right.
  pub inline fn span(left: Position, right: Position) Position {
    std.debug.assert(left.source == right.source);
    return .{.source = left.source, .start = left.start, .end = right.end};
  }

  pub inline fn intrinsic() Position {
    return .{
      .start = Cursor.unknown(),
      .end = Cursor.unknown(),
      .source = &IntrinsicSource,
    };
  }
};

/// A source provides content to be parsed. This is either a source file or a
/// (command-line) argument
pub const Source = struct {
  /// A source's descriptor specifies metadata about the source. This is used to
  /// refer to the source in position data of nodes and expressions.
  pub const Descriptor = struct {
    /// for files, the path to the file. for command line arguments, the name of
    /// the argument.
    name: []const u8,
    /// the absolute locator that identifies this source.
    locator: []const u8,
    /// true iff the source has been given as command-line argument
    argument: bool,
  };

  /// This source's metadata. The metadata will live longer than the source
  /// itself, which will be deallocated once it has been parsed completely.
  /// Therefore it is a pointer and is owned by the context.
  meta: *const Descriptor,
  /// the content of the source that is to be parsed
  content: []const u8,
  /// offsets if the source is part of a larger file.
  /// these will be added to line/column reporting.
  /// this feature is exists to support the testing framework.
  offsets: struct {
    line: usize = 0,
    column: usize = 0
  },
  /// the locator minus its final element, used for resolving
  /// relative locators inside this source.
  locator_ctx: []const u8,

  /// returns the position inside the source at the given cursor
  /// (starts & ends there)
  pub inline fn at(s: *const Source, cursor: Cursor) Position {
    return s.between(cursor, cursor);
  }

  /// returns the position inside the source between start and end
  pub inline fn between(s: *const Source, start: Cursor, end: Cursor) Position {
    return .{.source = s.meta, .start = start, .end = end};
  }
};

/// A lexer token. emitted by the lexer.
pub const Token = enum(u16) {
  /// A comment. Ends either before or after a linebreak depending on whether
  /// it's a comment-break or comment-nonbreak [7.5.1]
  comment,
  /// Indentation whitespace (indent-capture, indent) [7.5.2]
  indent,
  /// Non-significant [7.5.2] or significant (sig-ws) [7.5.3] whitespace.
  /// The lexer is unable to distinguish these in all contexts; however it
  /// will only return line breaks as space in contexts where it cannot be
  /// significant.
  space,
  /// possibly significant linebreak (sig-br) [7.5.3]
  /// also used for non-significant line breaks in trailing empty lines of a
  /// block or argument – parser will dump those.
  ws_break,
  /// Paragraph separator (sig-parsep) [7.5.3]
  parsep,
  /// Escape sequence (escaped-br [7.5.3], escape [7.5.4])
  escape,
  /// Literal text (literal) [7.5.4]
  literal,
  /// ':,' that closes currently open command [7.6]
  closer,
  /// command character inside block config [7.11]
  ns_sym,
  /// symbol reference [7.6.1] started with a command character.
  /// will never be '\end' since that is covered by block_end_open.
  symref,
  /// text identifying a symbol or config item name [7.6.1]
  identifier,
  /// '::' introducing accessor and containing identifier [7.6.2]
  access,
  /// Assignment start ':=', must be followed by arglist or block [7.6.4]
  assign,
  /// '(' that is starting a list of arguments [7.9]
  list_start,
  /// ')' that is closing a list of arguments [7.9]
  list_end,
  /// ',' separating list arguments [7.9]
  comma,
  /// '=' or ':=' separating argument name from value [7.9]
  name_sep,
  /// '=' introducing id-setter [7.9]
  id_set,
  /// ':' after identifier or arglist starting a block list [7.10]
  /// also used after block config to start swallow.
  blocks_sep,
  /// ':=' starting, or ':' starting or ending, a block name [7.10]
  block_name_sep,
  /// '\end(' (with \ being the appropriate command character) [7.10]
  /// must be followed up by space, identifier, and list_end
  block_end_open,
  /// name inside '\end('. This token implies that the given name is the
  /// expected one. Either call_id, wrong_call_id or skipping_call_id will
  /// occur inside of '\end(' but the occurring token may have zero length if
  /// the '\end(' does not contain a name.
  /// The token will also include all whitespace inside `\end(…)`.
  ///
  call_id,
  /// decimal digits specifying the swallow depth [7.10]
  swallow_depth,
  /// '<' when introducing block configuration
  diamond_open,
  /// '>' specifying swallowing [7.10] or closing block config [7.11]
  diamond_close,
  /// any special character inside a block with special syntax [7.12]
  special,
  /// signals the end of the current source.
  end_source,

  // -----------
  // following here are error tokens

  /// emitted when a block name ends at the end of a line without a closing :.
  missing_block_name_sep,
  /// single code point that is not allowed in Nyarna source
  illegal_code_point,
  /// '(' inside an arglist when not part of a sub-command structure
  illegal_opening_parenthesis,
  /// ':' after an expression that would start blocks when inside an argument
  /// list.
  illegal_blocks_start_in_args,
  /// command character inside a block name or id_setter
  illegal_command_char,
  /// non-identifier characters occurring where an identifier is expected
  illegal_characters,
  /// indentation which contains both tab and space characters
  mixed_indentation,
  /// indentation which contains a different indentation character
  /// (tab or space) than what the current block specified to use.
  illegal_indentation,
  /// content behind a ':', ':<…>' or ':>'.
  illegal_content_at_header,
  /// character that is not allowed inside of an identifier.
  illegal_character_for_id,
  /// '\end' without opening parenthesis following
  invalid_end_command,
  /// '\end(' with \ being the wrong command character
  wrong_ns_end_command,
  /// identifier inside '\end(' with unmatchable name.
  /// will be yielded for length 0 if identifier is missing but non-empty
  /// name is expected.
  wrong_call_id,
  /// all subsequent values are skipping_call_id.
  /// skipping_call_id signals that a number of '\end(…)' constructs is
  /// missing. It is emitted inside a '\end(…)' construct that contains an id
  /// that is not that of the current level, but that of some level above.
  /// the distance to skipping_call_id - 1 is how many levels were skipped.
  skipping_call_id,
  _,

  pub fn isError(t: Token) bool {
    return @enumToInt(t) >= @enumToInt(Token.illegal_code_point);
  }

  pub fn numSkippedEnds(t: Token) u32 {
    return @enumToInt(t) - @enumToInt(Token.skipping_call_id) + 1;
  }
};

pub const Locator = struct {
  const Error = error {
    parse_error
  };

  repr: []const u8,
  resolver: ?[]const u8,
  path: []const u8,

  pub fn parse(input: []const u8) !Locator {
    // TODO: render error
    if (input.len == 0) {
      return Error.parse_error;
    }
    var ret = Locator{.repr = input, .resolver = null, .path = undefined};
    if (input[0] == '.') {
      const end = std.mem.indexOfScalar(u8, input[1..], '.') orelse
        return Error.parse_error;
      ret.resolver = input[1..end];
      ret.path = input[end+1..];
    } else {
      ret.path = input;
    }
  }

  pub fn parent(self: Locator) Locator {
    if (self.path.len == 0) return null;
    const end = std.mem.lastIndexOfScalar(u8, self.path, '.') orelse 0;
    return if (self.resolver) |res| Locator{
      .repr = self.repr[0..res.len + 2 + end],
      .resolver = res,
      .path = self.path[0..end]
    } else Locator{
      .repr = self.repr[0..end],
      .resolver = null,
      .path = self.path[0..end]
    };
  }
};

pub const BlockConfig = struct {
  /// Describes changes in command characters. either .from or .to may be 0,
  /// but not both. If .from is 0, .to gets to be a new command character
  /// with an empty namespace.
  /// If .to is 0, .from is to be a command character that gets disabled.
  /// If neither is 0, the command character .from will be disabled and .to
  /// will take its place, referring to .from's namespace.
  pub const Map = struct {
    /// mappings are not defined by intrinsic functions, therefore position is
    /// always in some Input.
    pos: Position,
    from: u21,
    to: u21
  };

  pub const SyntaxDef =  struct {
    pos: Position,
    index: usize
  };

  syntax: ?SyntaxDef,
  map: []Map,
  off_colon: ?Position,
  off_comment: ?Position,
  full_ast: ?Position,

  pub fn empty() BlockConfig {
    return .{
      .syntax = null, .map = &.{}, .off_colon = null, .off_comment = null,
      .full_ast = null
    };
  }
};

pub const Node = struct {
  pub const Literal = struct {
    kind: enum {text, space},
    content: []const u8,

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
  pub const UnresolvedSymref = struct {
    ns: u15,
    name: []const u8,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  pub const ResolvedSymref = struct {
    ns: u15,
    sym: *Symbol,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  pub const Access = struct {
    subject: *Node,
    id: []const u8,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  pub const Assign = struct {
    target: union(enum) {
      unresolved: *Node,
      resolved: struct {
        target: *Symbol.Variable,
        path: []usize,
        t: Type
      },
    },
    replacement: *Node,

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
  pub const ResolvedCall = struct {
    ns: u15,
    target: *Expression,
    args: []*Node,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  pub const Branches = struct {
    condition: *Node,
    branches: []*Node,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  /// generated by location syntax. different from a call to \Location in that
  /// it may contain unresolved subnodes.
  pub const Location = struct {
    /// allocated separately to constrain size of Node.Data type.
    pub const Additionals = struct {
      primary: ?Position,
      varargs: ?Position,
      varmap: ?Position,
      mutable: ?Position,
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
  /// generated by definition syntax. different from a call to \Definition in
  /// that it may contain unresolved subnodes.
  pub const Definition = struct {
    name: *Node.Literal,
    root: ?Position,
    content: *Node,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  /// Typegen nodes are nodes that generate types. They are created by prototype
  /// functions (e.g. \List, \Concat, \Textual etc). They may need multiple
  /// passes for interpretation since they can refer to each other (e.g. inside
  /// of a \declare command).
  pub const Typegen = struct {
    pub const Content = union(enum) {
      optional: struct {
        inner: *Node,
      },
      concat: struct {
        inner: *Node,
      },
      list: struct {
        inner: *Node,
      },
      paragraphs: struct {
        inners: []*Node,
        auto: ?*Node,
      },
      map: struct {
        key: *Node,
        value: *Node,
      },
      record: struct {
        fields: []*Location,
      },
      intersection: struct {
        types: []*Node,
      },
      textual: struct {
        categories: []*Node,
        include_chars: *Node,
        exclude_chars: *Node,
      },
      numeric: struct {
        min: ?*Node,
        max: ?*Node,
        decimals: ?*Node,
      },
      float: struct {
        precision: *Node,
      },
      @"enum": struct {
        values: []*Node,
      },
    };
    /// this holds the (possibly unfinished) type and can also be undefined,
    /// depending on the current pass.
    generated: Type = undefined,
    /// defines which prototype is instaniated and which arguments have been
    /// given.
    content: Content,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };
  /// Funcgen nodes define functions. Just like Typegen nodes, they may need
  /// multiple passes to be processed.
  pub const Funcgen = struct {
    pub const LocRef = union(enum) {
      node: *Location,
      value: *Value.Location,
    };

    /// params are initially unresolved. Trying to interpret the Funcgen may
    /// successfully resolve the params while failing to interpret the body
    /// completely.
    params: union(enum) {
      /// This is whatever the input gave, with no checking whether it is a
      /// structure that can be associated to Concat(Location). That check only
      /// happens when interpreting the Funcgen Node, either directly or
      /// step-by-step within \declare.
      unresolved: *Node,
      /// the result of associating the original node with Concat(Location).
      /// only used during \declare processing.
      resolved: struct {
        locations: []LocRef,
        variables: VariableContainer,
      },
    },
    params_ns: u15,
    returns: ?*Node,
    body: *Node,
    /// used during fixpoint operation for type inference.
    /// unused if `returns` is set.
    cur_returns: Type = undefined,

    pub inline fn node(self: *@This()) *Node {
      return Node.parent(self);
    }
  };

  pub const Data = union(enum) {
    access: Access,
    assign: Assign,
    branches: Branches,
    concat: Concat,
    definition: Definition,
    expression: *Expression,
    funcgen: Funcgen,
    literal: Literal,
    location: Location,
    paras: Paras,
    resolved_call: ResolvedCall,
    resolved_symref: ResolvedSymref,
    typegen: Typegen,
    unresolved_call: UnresolvedCall,
    unresolved_symref: UnresolvedSymref,
    poison,
    void,
  };

  pos: Position,
  data: Data,

  fn parent(it: anytype) *Node {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch(t) {
      Access =>  offset(Data, "access"),
      Assign => offset(Data, "assign"),
      Branches => offset(Data, "branches"),
      Concat => offset(Data, "concat"),
      Definition => offset(Data, "definition"),
      *Expression => offset(Data, "expression"),
      Funcgen => offset(Data, "funcgen"),
      Literal => offset(Data, "literal"),
      Location => offset(Data, "location"),
      Paras => offset(Data, "paras"),
      ResolvedCall => offset(Data, "resolved_call"),
      ResolvedSymref => offset(Data, "resolved_symref"),
      Typegen => offset(Data, "typegen"),
      UnresolvedCall => offset(Data, "unresolved_call"),
      UnresolvedSymref => offset(Data, "unresolved_symref"),
      else => unreachable
    };
    return @fieldParentPtr(Node, "data", @intToPtr(*Data, addr));
  }
};

pub const Function = struct {
  /// Function defined in Nyarna code.
  const Nyarna = struct {
    variables: VariableContainer,
    body: *Expression,
  };
  /// externally defined function, pre-defined by the Nyarna processor or
  /// registered via Nyarna's API.
  const External = struct {
    /// tells the interpreter under which index to look up the implementation.
    impl_index: usize,
    /// whether the implementation depends on the namespace by which the it is
    /// called. This is used for for intrinsic keywords such as \declare,
    /// \import or \func.
    ns_dependent: bool,
  };
  const Data = union(enum) {
    ny: Nyarna,
    ext: External,
  };

  callable: *const Type.Callable,
  /// if the function is named, this is the reference to the symbol naming the
  /// function.
  name: ?*Symbol,
  data: Data,
  defined_at: Position,
  /// reference to the current stack frame of this function.
  /// null if no calls to this function are currently being evaluated.
  cur_frame: ?[*]StackItem = null,

  pub inline fn sig(self: *const Function) *const Type.Signature {
    return self.callable.sig;
  }
};

pub const Symbol = struct {
  /// A variable defined in Nyarna code.
  pub const Variable = struct {
    t: Type,
    /// pointer to the stack position that contains the current value.
    /// the variable's context (e.g. function, var- or const-block) is
    /// responsible for updating this value.
    ///
    /// the initial value is null, however due to Nyarna's semantics, any access
    /// will always happen when cur_value is non-null.
    cur_value: ?*StackItem = null,

    pub inline fn sym(self: *Variable) *Symbol {
      return Symbol.parent(self);
    }
  };

  pub const Data = union(enum) {
    func: *Function,
    variable: Variable,
    @"type": Type,
    prototype: Prototype,
  };

  defined_at: Position,
  name: []const u8,
  data: Data,

  fn parent(it: anytype) *Symbol {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch(t) {
      *Function => offset(Data, "func"),
      Variable => offset(Data, "variable"),
      Type => offset(Data, "type"),
      Prototype => offset(Data, "prototype"),
      else => unreachable
    };
    return @fieldParentPtr(Symbol, "data", @intToPtr(*Data, addr));
  }
};

/// part of any structure that defines variables.
/// contains a list of variables, the list itself must not be modified after
/// creation.
pub const VariableContainer = []*Symbol.Variable;

/// workaround for https://github.com/ziglang/zig/issues/6611
fn offset(comptime T: type, comptime field: []const u8) usize {
  var data = @unionInit(T, field, undefined);
  return @ptrToInt(&@field(data, field)) - @ptrToInt(&data);
}

pub const Type = union(enum) {
  pub const Signature = struct {
    pub const Parameter = struct {
      pos: Position,
      name: []const u8,
      ptype: Type,
      capture: enum {default, varargs, mutable},
      default: ?*Expression,
      config: ?BlockConfig,
    };

    parameters: []Parameter,
    primary: ?u21,
    varmap: ?u21,
    auto_swallow: ?struct{
      param_index: usize,
      depth: usize,
    },
    returns: Type,

    pub fn isKeyword(sig: *const Signature) bool {
      return sig.returns.is(.ast_node);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Intersection = struct {
    scalar: ?Type,
    types: []Type,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Concat = struct {
    inner: Type,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Optional = struct {
    inner: Type,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Paragraphs = struct {
    inner: []Type,
    auto: ?u21,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const List = struct {
    inner: Type,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Map = struct {
    key: Type,
    value: Type,

    pub inline fn pos(self: *@This()) Position {
      return Structural.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Structural.typedef(self);
    }
  };

  pub const Callable = struct {
    pub const Kind = enum {function, @"type", prototype};
    /// allocated separately for the sole reason of making the Structural union
    /// smaller.
    sig: *Signature,
    /// This determines the position of this type in the type hierarchy.
    /// For a Callable c,
    ///    c < Type iff c.kind == type
    ///    c < Prototype iff c.kind == prototype
    /// no relation to Type resp. Prototype otherwise.
    kind: Kind,
    /// representative of this type in the type lattice.
    /// the representative has no primary, varmap, or auto_swallow value, and
    /// its parameters have empty names, always default-capture, and have
    /// neither config nor default.
    ///
    /// undefined for keywords which cannot be used as Callable values and
    /// therefore never interact with the type lattice.
    repr: *Callable,

    pub inline fn typedef(self: *const @This()) Type {
      std.debug.print("Callable.typedef({s})\n", .{@tagName(self.kind)});
      return Structural.typedef(self);
    }
  };

  /// types with structural equivalence
  pub const Structural = union(enum) {
    optional: Optional,
    concat: Concat,
    paragraphs: Paragraphs,
    list: List,
    map: Map,
    /// general type for anything callable, has flag for whether it's a type
    callable: Callable,
    intersection: Intersection,

    fn parent(it: anytype) *Structural {
      const t = @typeInfo(@TypeOf(it)).Pointer.child;
      const addr = @ptrToInt(it) - switch(t) {
        Optional => offset(Structural, "optional"),
        Concat => offset(Structural, "concat"),
        Paragraphs => offset(Structural, "paragraphs"),
        List => offset(Structural, "list"),
        Map => offset(Structural, "map"),
        Callable => offset(Structural, "callable"),
        Intersection => offset(Structural, "intersection"),
        else => unreachable
      };
      return @intToPtr(*Structural, addr);
    }

    /// calculates the position from a pointer to Textual, Numeric, Float,
    /// Enum, or Record
    fn pos(it: anytype) Position {
      return parent(it).at;
    }

    fn typedef(it: anytype) Type {
      return .{.structural = parent(it)};
    }
  };

  /// parameters of a Textual type. The set of allowed characters is logically
  /// defined as follows:
  ///
  ///  * all characters in include.chars are in the set.
  ///  * all characters with a category in include.categories that are not in
  ///    exclude are in the set.
  pub const Textual = struct {
    constructor: *Callable,
    include: struct {
      chars: []const u21,
      categories: unicode.CategorySet,
    },
    exclude: []const u21,

    pub inline fn pos(self: *@This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }
  };

  /// parameters of a Numeric type.
  pub const Numeric = struct {
    constructor: *Callable,
    min: i64,
    max: i64,
    decimals: u32,

    pub inline fn pos(self: *@This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }
  };

  /// parameters of a Float type.
  pub const Float = struct {
    pub const Precision = enum {
      half, single, double, quadruple, octuple
    };

    constructor: *Callable,
    precision: Precision,

    pub inline fn pos(self: *@This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }
  };

  /// parameters of an Enum type.
  pub const Enum = struct {
    constructor: *Callable,
    /// retains the order of the enum values.
    /// must not be modified after creation.
    values: std.StringArrayHashMapUnmanaged(u0),

    pub inline fn pos(self: *const @This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }

    pub inline fn instantiated(self: *const @This()) *Instantiated {
      return Instantiated.parent(self);
    }
  };

  /// parameters of a Record type. contains the signature of its constructor.
  /// its fields are derived from that signature.
  pub const Record = struct {
    constructor: *Callable,

    pub fn pos(self: *@This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
     return Instantiated.typedef(self);
    }
  };

  pub const Instantiated = struct {
    const Data = union(enum) {
      textual: Textual,
      numeric: Numeric,
      float: Float,
      tenum: Enum,
      record: Record,
    };
    /// position at which the type has been declared.
    at: Position,
    /// name of the type, if it has any.
    name: ?*Symbol,
    /// kind and parameters of the type
    data: Data,

    fn parent(it: anytype) *Instantiated {
      const t = @typeInfo(@TypeOf(it)).Pointer.child;
      const addr = @ptrToInt(it) - switch(t) {
        Textual =>  offset(Data, "textual"),
        Numeric => offset(Data, "numeric"),
        Float => offset(Data, "float"),
        Enum => offset(Data, "tenum"),
        Record => offset(Data, "record"),
        else => unreachable
      };
      return @fieldParentPtr(Instantiated, "data", @intToPtr(*Data, addr));
    }

    /// calculates the position from a pointer to Textual, Numeric, Float,
    /// Enum, or Record
    pub fn pos(it: anytype) Position {
      return parent(it).at;
    }

    fn typedef(it: anytype) Type {
      return .{.instantiated = parent(it)};
    }
  };

  /// unique types predefined by Nyarna
  intrinsic: enum {
    void, prototype, schema, extension, ast_node, block_header,
    @"type", space, literal, raw,
    location, definition, backend,
    poison, every
  },

  structural: *Structural,
  /// types with name equivalence that are instantiated by user code
  instantiated: *Instantiated,

  pub const HashContext = struct {
    pub fn hash(_: HashContext, t: Type) u64 {
      return switch (t) {
        .intrinsic => |i| @intCast(u64, @enumToInt(i)),
        .structural => |s| @intCast(u64, @ptrToInt(s)),
        .instantiated => |in| @intCast(u64, @ptrToInt(in)),
      };
    }

    pub fn eql(_: HashContext, a: Type, b: Type) bool {
      return a.eql(b);
    }
  };

  pub fn isScalar(t: @This()) bool {
    return switch (t) {
      .intrinsic => |it|
        switch (it) {.space, .literal, .raw => true, else => false},
      .structural => false,
      .instantiated => |it|
        switch (it.data) {
          .textual, .numeric, .float, .tenum => true, else => false,
        },
    };
  }

  pub inline fn is(t: Type, comptime expected: anytype) bool {
    return switch (t) {.intrinsic => |it| it == expected, else => false};
  }

  pub inline fn isStructural(t: Type, comptime expected: anytype) bool {
    return switch (t) {
      .structural => |strct| strct.* == expected,
      else => false,
    };
  }

  pub inline fn eql(a: Type, b: Type) bool {
    return switch (a) {
      .intrinsic => |ia| switch (b) {
        .intrinsic => |ib| ia == ib, else => false,
      },
      .instantiated => |ia|
        switch (b) {.instantiated => |ib| ia == ib, else => false},
      .structural => |sa|
        switch (b) {.structural => |sb| sa == sb, else => false},
    };
  }

  fn formatParameterized(
      comptime fmt: []const u8, opt: std.fmt.FormatOptions, name: []const u8,
      inners: []const Type, writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeAll(name);
    try writer.writeByte('<');
    for (inners) |inner, index| {
      if (index > 0) {
        try writer.writeAll(", ");
      }
      try inner.format(fmt, opt, writer);
    }
    try writer.writeByte('>');
  }

  pub fn format(
      self: Type, comptime fmt: []const u8, opt: std.fmt.FormatOptions,
      writer: anytype) @TypeOf(writer).Error!void {
    switch (self) {
      .intrinsic => |it| try writer.writeAll(@tagName(it)),
      .structural => |struc| try switch (struc.*) {
        .optional => |op| formatParameterized(
          fmt, opt, "Optional", &[_]Type{op.inner}, writer),
        .concat => |con| formatParameterized(
          fmt, opt, "Concat", &[_]Type{con.inner}, writer),
        .paragraphs => |para| formatParameterized(
          fmt, opt, "Paragraphs", para.inner, writer),
        .list => |list| formatParameterized(
          fmt, opt, "List", &[_]Type{list.inner}, writer),
        .map => |map| formatParameterized(
          fmt, opt, "Optional", &[_]Type{map.key, map.value}, writer),
        .callable => |clb| {
          try writer.writeAll(switch (clb.kind) {
            .function => @as([]const u8, "[function] "),
            .@"type" => "[type] ",
            .prototype => "[prototype] ",
          });
          try writer.writeByte('(');
          for (clb.sig.parameters) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try param.ptype.format(fmt, opt, writer);
          }
          try writer.writeAll(") -> ");
          try clb.sig.returns.format(fmt, opt, writer);
        },
        .intersection => |inter| {
          try writer.writeByte('{');
          if (inter.scalar) |scalar| try scalar.format(fmt, opt, writer);
          for (inter.types) |inner, i| {
            if (i > 0 or inter.scalar != null) try writer.writeAll(", ");
            try inner.format(fmt, opt, writer);
          }
          try writer.writeByte('}');
          return;
        },
      },
      .instantiated => |it| {
        if (it.name) |sym| {
          try writer.writeAll(sym.name);
        } else {
          // TODO: write representation of type
          try writer.writeAll("<anonymous>");
        }
      }
    }
  }

  pub fn formatAll(types: []const Type, comptime fmt: []const u8,
                   options: std.fmt.FormatOptions, writer: anytype)
    @TypeOf(writer).Error!void {
  for (types) |t, i| {
    if (i > 0) try writer.writeAll(", ");
    try t.format(fmt, options, writer);
  }
}

  pub inline fn formatter(self: Type) std.fmt.Formatter(format) {
    return .{.data = self};
  }

  pub inline fn formatterAll(types: []const Type)
      std.fmt.Formatter(formatAll) {
    return .{.data = types};
  }
};

pub const Prototype = enum {
  textual, numeric, float, @"enum", optional, concat, list, paragraphs, map,
  record, intersection,
};

pub const Expression = struct {
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
    path: []usize,
    expr: *Expression,
  };
  /// retrieval of the value of a substructure
  pub const Access = struct {
    subject: *Expression,
    /// list of indexes that identify which part of the value is to be
    /// retrieved.
    path: []usize,
  };
  /// retrieval of a variable's value
  pub const VarRetrieval = struct {
    variable: *Symbol.Variable,
  };
  /// concatenation
  pub const Concatenation = []*Expression;
  /// a literal value
  pub const Literal = struct {
    value: Value,

    pub fn expr(self: *@This()) *Expression {
      return Expression.parent(self);
    }
  };
  // if or switch expression
  pub const Branches = struct {
    condition: *Expression,
    branches: []*Expression,
  };
  /// an ast subtree
  pub const Ast = struct {
    root: *Node,
  };

  pub const Data = union(enum) {
    access: Access,
    assignment: Assignment,
    branches: Branches,
    call: Call,
    concatenation: Concatenation,
    literal: Literal,
    var_retrieval: VarRetrieval,
    poison, void,
  };

  pos: Position,
  data: Data,
  /// May be imposed upon it by its context [8.3]. Evaluating this expression
  /// will yield a value with a Type in E_{expected_type}.
  expected_type: Type,

  fn parent(it: anytype) *Expression {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch(t) {
      Call => offset(Data, "call"),
      Assignment => offset(Data, "assignment"),
      Access => offset(Data, "access"),
      Literal => offset(Data, "literal"),
      else => unreachable
    };
    return @fieldParentPtr(Expression, "data", @intToPtr(*Data, addr));
  }

  pub inline fn fillPoison(e: *Expression, at: Position) void {
    e.* = .{
      .pos = at,
      .data = .{
        .literal = .{
          .value = .{
            .origin = at,
            .data = .poison
          }
        }
      },
      .expected_type = .{.intrinsic = .poison},
    };
  }

  pub inline fn fillVoid(e: *Expression, at: Position) void {
    e.* = .{
      .pos = at,
      .data = .{
        .literal = .{
          .value = .{
            .origin = at,
            .data = .void
          }
        }
      },
      .expected_type = .{.intrinsic = .void},
    };
  }
};

pub const Value = struct {
  /// a Space, Literal, Raw or Textual value
  pub const TextScalar = struct {
    t: Type,
    content: []const u8,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Numeric value
  pub const Number = struct {
    t: *const Type.Numeric,
    content: i64,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Float value
  pub const FloatNumber = struct {
    pub const Content = union {
      half: f16,
      single: f32,
      double: f64,
      quadruple: f128,
    };

    t: *const Type.Float,
    content: Content,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// an Enum value
  pub const Enum = struct {
    t: *const Type.Enum,
    index: usize,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Record value
  pub const Record = struct {
    t: *const Type.Record,
    fields: []*Value,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Concat value
  pub const Concat = struct {
    t: *const Type.Concat,
    content: std.ArrayList(*Value),

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Paragraphs value
  pub const Para = struct {
    t: *const Type.Paragraphs,
    content: std.ArrayList(*Value),

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a List value
  pub const List = struct {
    t: *const Type.List,
    content: std.ArrayList(*Value),

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Map value
  pub const Map = struct {
    const Items = std.HashMap(*Value, *Value, Value.HashContext, 50);

    t: *const Type.Map,
    items: Items,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const TypeVal = struct {
    t: Type,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const PrototypeVal = struct {
    pt: Prototype,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const FuncRef = struct {
    func: *Function,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Location = struct {
    name: *Value.TextScalar,
    tloc: Type,
    default: ?*Expression = null,
    primary: ?Position = null,
    varargs: ?Position = null,
    varmap: ?Position = null,
    mutable: ?Position = null,
    header: ?*BlockHeader = null,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }

    pub inline fn withDefault(self: *Location, v: *Expression) *Location {
      self.default = v;
      return self;
    }

    pub inline fn withHeader(self: *Location, v: *BlockHeader) *Location {
      self.header = v;
      return self;
    }

    pub inline fn withPrimary(self: *Location, v: Position) *Location {
      self.primary = v;
      return self;
    }

    pub inline fn withVarargs(self: *Location, v: Position) *Location {
      self.varargs = v;
      return self;
    }
  };

  pub const Definition = struct {
    name: *Value.TextScalar,
    // must be either function or type value
    content: *Value,
    root: ?Position = null,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Ast = struct {
    root: *Node,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  /// This value type is used to read in block headers within SpecialSyntax,
  /// e.g. the default block configuration of function parameters.
  pub const BlockHeader = struct {
    config: ?BlockConfig,
    swallow_depth: ?u21,

    pub inline fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Data = union(enum) {
    text: TextScalar,
    number: Number,
    float: FloatNumber,
    @"enum": Enum,
    record: Record,
    concat: Concat,
    para: Para,
    list: List,
    map: Map,
    @"type": TypeVal,
    prototype: PrototypeVal,
    funcref: FuncRef,
    location: Location,
    definition: Definition,
    ast: Ast,
    block_header: BlockHeader,
    void, poison
  };

  const HashContext = struct {
    pub fn hash(_: HashContext, v: *Value) u64 {
      return switch (v.data) {
        .text => |ts| std.hash_map.hashString(ts.content),
        .number => |num| @bitCast(u64, num.content),
        .float => |fl| switch (fl.t.precision) {
          .half => @intCast(u64, @bitCast(u16, fl.content.half)),
          .single => @intCast(u64, @bitCast(u32, fl.content.single)),
          .double => @bitCast(u64, fl.content.double),
          .quadruple, .octuple =>
            @truncate(u64, @bitCast(u128, fl.content.quadruple)),
        },
        .@"enum" => |ev| @intCast(u64, ev.index),
        else => unreachable,
      };
    }

    pub fn eql(_: HashContext, a: *Value, b: *Value) bool {
      return switch (a.data) {
        .text => |ts| std.hash_map.eqlString(ts.content, b.data.text.content),
        .number => |num| num.content == b.data.number.content,
        .float => |fl| switch (fl.t.precision) {
          .half => fl.content.half == b.data.float.content.half,
          .single => fl.content.single == b.data.float.content.single,
          .double => fl.content.double == b.data.float.content.double,
          .quadruple, .octuple =>
            fl.content.quadruple == b.data.float.content.quadruple,
        },
        .@"enum" => |ev| ev.index == b.data.@"enum".index,
        else => unreachable,
      };
    }
  };

  origin: Position,
  data: Data,

  pub inline fn create(allocator: std.mem.Allocator, pos: Position,
                       content: anytype) !*Value {
    var ret = try allocator.create(Value);
    ret.origin = pos;
    ret.data = switch (@TypeOf(content)) {
      TextScalar   => .{.text         = content},
      Number       => .{.number       = content},
      FloatNumber  => .{.float        = content},
      Enum         => .{.enumval      = content},
      Record       => .{.record       = content},
      Concat       => .{.concat       = content},
      Para         => .{.para         = content},
      List         => .{.list         = content},
      Map          => .{.map          = content},
      TypeVal      => .{.@"type"      = content},
      PrototypeVal => .{.prototype    = content},
      FuncRef      => .{.funcref      = content},
      Definition   => .{.definition   = content},
      Ast          => .{.ast          = content},
      BlockHeader  => .{.block_header = content},
      else         => content
    };
    return ret;
  }

  fn parent(it: anytype) *Value {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch(t) {
      TextScalar   => offset(Data, "text"),
      Number       => offset(Data, "number"),
      FloatNumber  => offset(Data, "float"),
      Enum         => offset(Data, "enum"),
      Record       => offset(Data, "record"),
      Concat       => offset(Data, "concat"),
      Para         => offset(Data, "para"),
      List         => offset(Data, "list"),
      Map          => offset(Data, "map"),
      TypeVal      => offset(Data, "type"),
      PrototypeVal => offset(Data, "prototype"),
      FuncRef      => offset(Data, "funcref"),
      Location     => offset(Data, "location"),
      Definition   => offset(Data, "definition"),
      Ast          => offset(Data, "ast"),
      BlockHeader  => offset(Data, "block_header"),
      else => unreachable
    };
    return @fieldParentPtr(Value, "data", @intToPtr(*Data, addr));
  }
};

/// A module represents a loaded file.
pub const Module = struct {
  /// exported symbols
  symbols: []*Symbol,
  /// the root expression contained in the file
  root: *Expression,
  // TODO: locator (?)
};

pub const NodeGenerator = struct {
  const Self = @This();

  allocator: std.mem.Allocator,

  pub fn init(allocator: std.mem.Allocator) NodeGenerator {
    return .{
      .allocator = allocator,
    };
  }

  inline fn create(self: *Self) !*Node {
    return self.allocator.create(Node);
  }

  pub inline fn node(self: *Self, pos: Position, content: Node.Data) !*Node {
    const ret = try self.create();
    ret.* = .{.pos = pos, .data = content};
    return ret;
  }

  pub inline fn access(self: *Self, pos: Position, content: Node.Access)
      !*Node.Access {
    return &(try self.node(pos, .{.access = content})).data.access;
  }

  pub inline fn assign(self: *Self, pos: Position, content: Node.Assign)
      !*Node.Assign {
    return &(try self.node(pos, .{.assign = content})).data.assign;
  }

  pub inline fn branches(self: *Self, pos: Position, content: Node.Branches)
      !*Node.Branches {
    return &(try self.node(pos, .{.branches = content})).data.branches;
  }

  pub inline fn concat(self: *Self, pos: Position, content: Node.Concat)
      !*Node.Concat {
    return &(try self.node(pos, .{.concat = content})).data.concat;
  }

  pub inline fn definition(self: *Self, pos: Position,
                            content: Node.Definition) !*Node.Definition {
    return &(try self.node(pos, .{.definition = content})).data.definition;
  }

  pub inline fn expression(self: *Self, content: *Expression)
      !*Node {
    return self.node(content.pos, .{.expression = content});
  }

  pub inline fn funcgen(self: *Self, pos: Position, returns: ?*Node,
                        params: *Node, params_ns: u15, body: *Node)
      !*Node.Funcgen {
    return &(try self.node(pos, .{.funcgen = .{
      .returns = returns, .params = .{.unresolved = params},
      .params_ns = params_ns, .body = body,
    }})).data.funcgen;
  }

  pub inline fn literal(self: *Self, pos: Position, content: Node.Literal)
      !*Node.Literal {
    return &(try self.node(pos, .{.literal = content})).data.literal;
  }

  pub inline fn location(self: *Self, pos: Position, content: Node.Location)
      !*Node.Location {
    return &(try self.node(pos, .{.location = content})).data.location;
  }

  pub fn locationFromValue(
      self: *Self, ctx: nyarna.Context, value: *Value.Location)
      !*Node.Location {
    const loc_node = try self.location(value.value().origin, .{
      .name = try self.literal(
        value.name.value().origin, .{
          .kind = .text, .content = value.name.content,
        }),
      .@"type" = try self.expression(
        try ctx.createValueExpr(value.value().origin, .{
          .@"type" = .{.t = value.tloc},
        })),
      .default = if (value.default) |d|
        try self.expression(d)
      else null,
      .additionals = null
    });
    if (value.primary != null or value.varargs != null or
        value.varmap != null or value.mutable != null or
        value.header != null) {
      const add = try self.allocator.create(Node.Location.Additionals);
      inline for ([_][]const u8{
          "primary", "varargs", "varmap", "mutable", "header"}) |field|
        @field(add, field) = @field(value, field);
      loc_node.additionals = add;
    }
    return loc_node;
  }

  pub inline fn paras(self: *Self, pos: Position, content: Node.Paras)
      !*Node.Paras {
    return &(try self.node(pos, .{.paras = content})).data.paras;
  }

  pub inline fn rcall(self: *Self, pos: Position, content: Node.ResolvedCall)
      !*Node.ResolvedCall {
    return &(try self.node(
      pos, .{.resolved_call = content})).data.resolved_call;
  }

  pub inline fn rsymref(self: *Self, pos: Position,
                        content: Node.ResolvedSymref) !*Node.ResolvedSymref {
    return &(try self.node(
      pos, .{.resolved_symref = content})).data.resolved_symref;
  }

  pub inline fn typegen(
      self: *Self, pos: Position, content: Node.Typegen.Content)
      !*Node.Typegen {
    return &(try self.node(
      pos, .{.typegen = .{.content = content}})).data.typegen;
  }

  pub inline fn ucall(self: *Self, pos: Position,
                      content: Node.UnresolvedCall) !*Node.UnresolvedCall {
    return &(try self.node(
      pos, .{.unresolved_call = content})).data.unresolved_call;
  }

  pub inline fn usymref(
      self: *Self, pos: Position, content: Node.UnresolvedSymref)
      !*Node.UnresolvedSymref {
    return &(try self.node(
      pos, .{.unresolved_symref = content})).data.unresolved_symref;
  }

  pub inline fn poison(self: *Self, pos: Position) !*Node {
    return self.node(pos, .poison);
  }

  pub inline fn @"void"(self: *Self, pos: Position) !*Node {
    return self.node(pos, .void);
  }
};

pub const ValueGenerator = struct {
  const Self = @This();

  dummy: u8 = 0, // needed for @fieldParentPtr to work

  inline fn allocator(self: *const Self) std.mem.Allocator {
    return @fieldParentPtr(nyarna.Context, "values", self).global();
  }

  inline fn create(self: *const Self) !*Value {
    return self.allocator().create(Value);
  }

  pub inline fn value(self: *const Self, pos: Position, data: Value.Data)
      !*Value {
    const ret = try self.create();
    ret.* = .{.origin = pos, .data = data};
    return ret;
  }

  pub inline fn textScalar(self: *const Self, pos: Position, t: Type,
                           content: []const u8) !*Value.TextScalar {
    return &(try self.value(
      pos, .{.text = .{.t = t, .content = content}})).data.text;
  }

  pub inline fn number(self: *const Self, pos: Position, t: *const Type.Numeric,
                       content: i64) !*Value.Number {
    return &(try self.value(
      pos, .{.number = .{.t = t, .content = content}})).data.number;
  }

  pub inline fn float(self: *const Self, pos: Position, t: *const Type.Float,
                      content: Value.FloatNumber.Content) !*Value.FloatNumber {
    return &(try self.value(
      pos, .{.float = .{.t = t, .content = content}})).data.float;
  }

  pub inline fn @"enum"(self: *const Self, pos: Position, t: *const Type.Enum,
                        index: usize) !*Value.Enum {
    return &(try self.value(
      pos, .{.@"enum" = .{.t = t, .index = index}})).data.@"enum";
  }

  pub inline fn record(self: *const Self, pos: Position, t: *const Type.Record)
      !*Value.Record {
    const fields =
      try self.allocator().alloc(*Value, t.callable.sig.parameters.len);
    errdefer self.allocator().free(fields);
    return &(try self.value(
      pos, .{.record = .{.t = t, .fields = fields}})).data.record;
  }

  pub inline fn concat(self: *const Self, pos: Position, t: *const Type.Concat)
      !*Value.Concat {
    return &(try self.value(pos, .{
      .concat = .{
        .t = t,
        .content = std.ArrayList(*Value).init(self.allocator()),
      },
    })).data.concat;
  }

  pub inline fn para(self: *const Self, pos: Position, t: *const Type.Paragraphs)
      !*Value.Para {
    return &(try self.value(pos, .{
      .para = .{
        .t = t,
        .content = std.ArrayList(*Value).init(self.allocator()),
      },
    })).data.para;
  }

  pub inline fn list(self: *const Self, pos: Position, t: *const Type.List)
      !*Value.List {
    return &(try self.value(pos, .{
      .list = .{
        .t = t,
        .content = std.ArrayList(*Value).init(self.allocator()),
      },
    })).data.list;
  }

  pub inline fn map(self: *const Self, pos: Position, t: *const Type.Map)
      !*Value.Map {
    return &(try self.value(pos, .{
      .map = .{
        .t = t,
        .items = Value.Map.Items.init(self.allocator()),
      },
    })).data.map;
  }

  pub inline fn @"type"(self: *const Self, pos: Position, t: Type)
      !*Value.TypeVal {
    return &(try self.value(
      pos, .{.@"type" = .{.t = t}})).data.@"type";
  }

  pub inline fn prototype(self: *const Self, pos: Position, pt: Prototype)
      !*Value.PrototypeVal {
    return &(try self.value(
      pos, .{.prototype = .{.pt = pt}})).data.prototype;
  }

  pub inline fn funcRef(self: *const Self, pos: Position, func: *Symbol)
      !*Value.FuncRef {
    std.debug.assert(func.data == .ext_func or func.data == .ny_func);
    return &(try self.value(
      pos, .{.funcref = .{.func = func}})).data.funcref;
  }

  pub inline fn location(
      self: *const Self, pos: Position, name: *Value.TextScalar,
      t: Type) !*Value.Location {
    return &(try self.value(
      pos, .{.location = .{.name = name, .tloc = t}})).data.location;
  }

  /// Generates an intrinsic location (contained positions are <intrinsic>).
  /// The given name must live at least as long as the Context.
  pub inline fn intLocation(self: *const Self, name: []const u8, t: Type)
      !*Value.Location {
    const name_val = try self.textScalar(Position.intrinsic(),
      .{.intrinsic = .literal}, name);
    return self.location(Position.intrinsic(), name_val, t);
  }

  pub inline fn definition(self: *const Self, pos: Position, name: *Value.TextScalar,
                           content: *Value) !*Value.Definition {
    return &(try self.value(pos,
      .{.definition = .{.name = name, .content = content}})).data.definition;
  }

  pub inline fn ast(self: *const Self, pos: Position, root: *Node) !*Value.Ast {
    return &(try self.value(pos, .{.ast = .{.root = root}})).data.ast;
  }

  pub inline fn blockHeader(self: *const Self, pos: Position, config: ?BlockConfig,
                            swallow_depth: ?u21) !*Value.BlockHeader {
    return &(try self.value(pos,
      .{.block_header = .{.config = config, .swallow_depth = swallow_depth}}
    )).data.block_header;
  }

  pub inline fn @"void"(self: *const Self, pos: Position) !*Value {
    return self.value(pos, .void);
  }

  pub inline fn poison(self: *const Self, pos: Position) !*Value {
    return self.value(pos, .poison);
  }
};