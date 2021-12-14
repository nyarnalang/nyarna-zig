const std = @import("std");
const unicode = @import("load/unicode.zig");

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

    pub fn pos(self: *Literal) Position {
      return Node.posOf(self);
    }
  };
  pub const Concatenation = struct {
    content: []*Node,
  };
  pub const Paragraphs = struct {
    pub const Item = struct {
      content: *Node,
      lf_after: usize
    };
    // lf_after of last item is ignored.
    items: []Item,
  };
  pub const UnresolvedSymRef = struct {
    ns: u15,
    name: []const u8,
  };
  pub const ResolvedSymRef = struct {
    ns: u15,
    sym: *Symbol,
  };
  pub const Access = struct {
    subject: *Node,
    id: []const u8,
  };
  pub const Assignment = struct {
    target: union(enum) {
      unresolved: *Node,
      resolved: struct {
        target: *Symbol.Variable,
        path: []usize,
        t: Type
      },
    },
    replacement: *Node,
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
  };
  pub const ResolvedCall = struct {
    ns: u15,
    target: *Expression,
    args: []*Node,
  };
  pub const Branches = struct {
    condition: *Node,
    branches: []*Node,
  };

  pub const Data = union(enum) {
    access: Access,
    assignment: Assignment,
    branches: Branches,
    literal: Literal,
    concatenation: Concatenation,
    paragraphs: Paragraphs,
    unresolved_symref: UnresolvedSymRef,
    resolved_symref: ResolvedSymRef,
    unresolved_call: UnresolvedCall,
    resolved_call: ResolvedCall,
    expression: *Expression,
    poisonNode,
    voidNode,
  };

  pos: Position,
  data: Data,

  fn parent(it: anytype) *Node {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch(t) {
      Access =>  offset(Data, "access"),
      Assignment => offset(Data, "assignment"),
      Literal => offset(Data, "literal"),
      Concatenation => offset(Data, "concatenation"),
      Paragraphs => offset(Data, "paragraphs"),
      UnresolvedSymRef => offset(Data, "unresolved_symref"),
      ResolvedSymRef => offset(Data, "resolved_symref"),
      UnresolvedCall => offset(Data, "unresolved_call"),
      ResolvedCall => offset(Data, "resolved_call"),
      *Expression => offset(Data, "expression"),
      else => unreachable
    };
    return @fieldParentPtr(Node, "data", @intToPtr(*Data, addr));
  }

  /// calculates the position from a pointer to any node kind
  fn posOf(it: anytype) Position {
    return parent(it).pos;
  }

  pub fn poison(allocator: *std.mem.Allocator, pos: Position) !*Node {
    var ret = try allocator.create(Node);
    ret.* = .{
      .pos = pos,
      .data = .poisonNode,
    };
    return ret;
  }

  pub fn genVoid(allocator: *std.mem.Allocator, pos: Position) !*Node {
    var ret = try allocator.create(Node);
    ret.* = .{
      .pos = pos,
      .data = .voidNode,
    };
    return ret;
  }
};

pub const Symbol = struct {
  /// externally defined function, pre-defined by Nyarna or registered via
  /// Nyarna's API.
  pub const ExtFunc = struct {
    callable: *const Type.Callable,
    /// tells the interpreter under which index to look up the implementation.
    impl_index: usize,
    /// whether the implementation of this extFunc depends on the namespace by
    /// which the it is called. This is used for for intrinsic keywords such as
    /// \declare and \import.
    ns_dependent: bool,
    /// reference to the current stack frame of this function.
    /// null if no calls to this function are currently being evaluated.
    cur_frame: ?[*]StackItem,

    pub fn sig(self: *const ExtFunc) *const Type.Signature {
      return self.callable.sig;
    }
  };

  /// Internal function, defined in Nyarna code.
  pub const NyFunc = struct {
    callable: *const Type.Callable,
    variables: VariableContainer,
    /// reference to the current stack frame of this function.
    /// null if no calls to this function are currently being evaluated.
    cur_frame: ?[*]StackItem,
    body: *Expression,

    pub fn sig(self: *const NyFunc) *const Type.Signature {
      return self.callable.sig;
    }
  };
  /// A variable defined in Nyarna code.
  pub const Variable = struct {
    t: Type,
    /// pointer to the stack position that contains the current value.
    /// the variable's context (e.g. function, var- or const-block) is
    /// responsible for updating this value.
    ///
    /// the initial value is null, however due to Nyarna's semantics, any access
    /// will always happen when cur_value is non-null.
    cur_value: ?*StackItem,
  };

  pub const Data = union(enum) {
    ext_func: ExtFunc,
    ny_func: NyFunc,
    variable: Variable,
    @"type": Type,
    prototype: Prototype,
  };

  defined_at: Position,
  name: []const u8,
  data: Data,
};

/// part of any structure that defines variables.
/// contains a list of variables, the list itself must not be modified after
/// creation.
pub const VariableContainer = []Symbol.Variable;

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
    include: struct {
      chars: []u8,
      categories: unicode.CategorySet,
    },
    exclude: []u8,

    pub inline fn pos(self: *@This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }
  };

  /// parameters of a Numeric type.
  pub const Numeric = struct {
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
    /// retains the order of the enum values.
    /// must not be modified after creation.
    values: std.StringArrayHashMapUnmanaged(u0),

    pub inline fn pos(self: *const @This()) Position {
      return Instantiated.pos(self);
    }

    pub inline fn typedef(self: *const @This()) Type {
      return Instantiated.typedef(self);
    }

    pub fn predefBoolean(alloc: *std.mem.Allocator) !Enum {
      var ret = Enum{.values = .{}};
      try ret.values.put(alloc, "false", 0);
      try ret.values.put(alloc, "true", 0);
      return ret;
    }
  };

  /// parameters of a Record type. contains the signature of its constructor.
  /// its fields are derived from that signature.
  pub const Record = struct {
    callable: *Callable,

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
};

pub const Prototype = enum {
  numeric, float, @"enum", optional, concat, list, paragraphs, record,
  intersection,
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

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Numeric value
  pub const Number = struct {
    t: *const Type.Numeric,
    content: i64,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Float value
  pub const FloatNumber = struct {
    t: *const Type.Float,
    content: union {
      half: f16,
      single: f32,
      double: f64,
      quadruple: f128,
    },

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// an Enum value
  pub const Enum = struct {
    t: *const Type.Enum,
    index: usize,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Record value
  pub const Record = struct {
    t: *const Type.Record,
    fields: []*Value,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Concat value
  pub const Concat = struct {
    t: *const Type.Concat,
    content: std.ArrayList(*Value),

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a List value
  pub const List = struct {
    t: *const Type.List,
    content: std.ArrayList(*Value),

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };
  /// a Map value
  pub const Map = struct {
    t: *const Type.Map,
    items: std.HashMap(*Value, *Value, Value.HashContext, 50),

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const TypeVal = struct {
    t: Type,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const PrototypeVal = struct {
    pt: Prototype,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const FuncRef = struct {
    /// ExtFunc or NyFunc
    func: *Symbol,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Location = struct {
    name: []const u8,
    tloc: Type,
    default: ?*Expression,
    primary: ?Position,
    varargs: ?Position,
    varmap: ?Position,
    mutable: ?Position,
    block_header: ?*BlockHeader,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }

    pub inline fn init(name: []const u8, t: Type) Location {
      return .{
        .name = name, .tloc = t, .default = null,
        .primary = null, .varargs = null, .varmap = null, .mutable = null,
        .block_header = null,
      };
    }

    pub inline fn with_default(self: *Location, v: *Expression) Location {
      self.default = v;
      return self.*;
    }

    pub inline fn with_header(self: *Location, v: *BlockHeader) Location {
      self.block_header = v;
      return self.*;
    }

    pub inline fn with_primary(self: *Location, v: Position) Location {
      self.primary = v;
      return self.*;
    }
  };

  pub const Definition = struct {
    name: []const u8,
    content: *Ast,
    root: ?Position,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Ast = struct {
    root: *Node,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  /// This value type is used to read in block headers within SpecialSyntax,
  /// e.g. the default block configuration of function parameters.
  pub const BlockHeader = struct {
    config: ?BlockConfig,
    swallow_depth: ?u21,

    pub fn value(self: *@This()) *Value {
      return Value.parent(self);
    }
  };

  pub const Data = union(enum) {
    text: TextScalar,
    number: Number,
    float: FloatNumber,
    enumval: Enum,
    record: Record,
    concat: Concat,
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
        .enumval => |ev| @intCast(u64, ev.index),
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
        .enumval => |ev| ev.index == b.data.enumval.index,
        else => unreachable,
      };
    }
  };

  origin: Position,
  data: Data,

  pub inline fn create(allocator: *std.mem.Allocator, pos: Position,
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
      Enum         => offset(Data, "enumval"),
      Record       => offset(Data, "record"),
      Concat       => offset(Data, "concat"),
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