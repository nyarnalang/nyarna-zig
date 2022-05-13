const std = @import("std");

pub const locations      = @import("model/locations.zig");
pub const Node           = @import("model/Node.zig");
pub const NodeGenerator  = @import("model/NodeGenerator.zig");
pub const Type           = @import("model/types.zig").Type;
pub const Symbol         = @import("model/Symbol.zig");
pub const ValueGenerator = @import("model/ValueGenerator.zig");

const unicode = @import("unicode.zig");
const lexing  = @import("model/lexing.zig");
const Globals = @import("Globals.zig");

pub usingnamespace lexing;

/// an item on the call stack.
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

  /// format the cursor in the form "<line>:<column>", without byte offset.
  pub fn format(
             self  : Cursor,
    comptime _     : []const u8,
             _     : std.fmt.FormatOptions,
             writer: anytype
  ) !void {
    try std.fmt.format(writer, "{}:{}", .{self.at_line, self.before_column});
  }

  pub fn formatter(self: Cursor) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};

/// Describes the origin of a construct. Usually start and end cursor are in a
/// source file, but can also come from command line parameters.
pub const Position = struct {
  source: *const Source.Descriptor,
  start : Cursor,
  end   : Cursor,

  const intrinsic_source = Source.Descriptor{
    .name     = "<intrinsic>",
    .locator  = Locator.parse(".std.intrinsic") catch unreachable,
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
      .start  = Cursor.unknown(),
      .end    = Cursor.unknown(),
      .source = &intrinsic_source,
    };
  }

  pub fn trimFrontChar(self: Position, byte_len: u3) Position {
    const nstart = Cursor{
      .at_line       = self.start.at_line,
      .before_column = self.start.before_column + 1,
      .byte_offset   = self.start.byte_offset + byte_len,
    };
    return Position{
      .source = self.source, .start = nstart, .end = self.end,
    };
  }

  /// returns the zero-length position at the start of the given position.
  pub fn before(self: Position) Position {
    return .{
      .source = self.source, .start = self.start, .end = self.start,
    };
  }

  /// returns the zero-length position at the end of the given position.
  pub fn after(self: Position) Position {
    return .{
      .source = self.source, .start = self.end, .end = self.end,
    };
  }

  pub fn isIntrinsic(self: Position) bool {
    return self.source == &intrinsic_source;
  }

  /// formats the position in the form
  ///
  ///   <path/to/file>(<start> - <end>)
  ///
  /// Positions in command-line arguments emit
  ///
  ///   argument "<name>"(<start> - <end>)
  ///
  /// instead. give "s" as specifier if you only want the <start>.
  pub fn format(
             self     : Position,
    comptime specifier: []const u8,
             _        : std.fmt.FormatOptions,
             writer   : anytype
  ) @TypeOf(writer).Error!void {
    if (self.source.argument) {
      try std.fmt.format(writer, "argument \"{s}\"", .{self.source.name});
    } else {
      try writer.writeAll(self.source.name);
    }
    if (comptime std.mem.eql(u8, specifier, "s")) {
      try std.fmt.format(writer, "({})", .{self.start.formatter()});
    } else {
      try std.fmt.format(
        writer, "({} - {})", .{self.start.formatter(), self.end.formatter()});
    }
  }

  pub fn formatter(self: Position) std.fmt.Formatter(format) {
    return .{.data = self};
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
    locator: Locator,
    /// true iff the source has been given as command-line argument
    argument: bool,

    /// generates the value that should go into Source.locator_ctx from the
    /// absolute locator.
    pub fn genLocatorCtx(self: *const Descriptor) []const u8 {
      const index = std.mem.lastIndexOf(u8, self.locator.repr, ".").?;
      return self.locator.repr[0..index + 1]; // include the '.'
    }
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
    line  : usize = 0,
    column: usize = 0,
  },
  /// the locator minus its final element, used for resolving relative locators
  /// inside this source. See Descriptor.genLocatorCtx().
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

pub const Locator = struct {
  const Error = error {
    parse_error
  };

  repr    : []const u8,
  resolver: ?[]const u8,
  path    : []const u8,

  pub fn parse(input: []const u8) !Locator {
    if (input.len == 0) return Error.parse_error;
    var ret = Locator{.repr = input, .resolver = null, .path = undefined};
    if (input[0] == '.') {
      const end = (std.mem.indexOfScalar(u8, input[1..], '.') orelse
        return Error.parse_error) + 1;
      ret.resolver = input[1..end];
      ret.path = input[end+1..];
    } else {
      ret.path = input;
    }
    return ret;
  }

  pub fn parent(self: Locator) Locator {
    if (self.path.len == 0) return null;
    const end = std.mem.lastIndexOfScalar(u8, self.path, '.') orelse 0;
    return if (self.resolver) |res| Locator{
      .repr     = self.repr[0..res.len + 2 + end],
      .resolver = res,
      .path     = self.path[0..end],
    } else Locator{
      .repr     = self.repr[0..end],
      .resolver = null,
      .path     = self.path[0..end],
    };
  }
};

/// BlockConfig describes the syntactic configuration of a block. [7.11]
/// this configuration specifies how to modify parser state when entering the
/// block.
pub const BlockConfig = struct {
  /// Describes changes in command characters. Each .from and .to may be 0.
  /// If both are 0, all command characters will be disabled.
  /// If .from is 0, .to gets to be a new command character with an empty ns.
  /// If .to is 0, .from is to be a command character that gets disabled.
  /// If neither is 0, the command character .from will be disabled and .to
  /// will take its place, referring to .from's namespace.
  pub const Map = struct {
    /// mappings are not defined by intrinsic functions, therefore position is
    /// always in some Input.
    pos : Position,
    from: u21,
    to  : u21
  };

  pub const SyntaxDef = struct {
    pos  : Position,
    index: usize,
  };

  pub const VarDef = struct {
    cmd_char: u21,
    name    : []const u8,
    pos     : Position,
  };

  /// custom syntax to use in this block.
  syntax: ?SyntaxDef = null,
  /// see doc of Map
  map: []Map = .{},
  /// whether begin-of-line colon shall be disabled
  off_colon: ?Position = null,
  /// whether comments shall be disabled
  off_comment: ?Position = null,
  /// whether keyword calls shall *not* be evaluated in this block.
  /// this requires the block being used in a context where it can return an
  /// Ast value.
  full_ast: ?Position = null,
  // the three kinds of variables that may be defined in a block config
  key  : ?VarDef = null,
  val  : ?VarDef = null,
  index: ?VarDef = null,
};

/// a type that has been specified at a certain position as target type.
/// usually a type of a location such as a parameter or variable.
pub const SpecType = struct {
  t  : Type,
  pos: Position,
};

/// a callable function.
pub const Function = struct {
  /// externally defined function, pre-defined by the Nyarna processor or
  /// registered via Nyarna's API.
  pub const External = struct {
    /// tells the interpreter under which index to look up the implementation.
    impl_index: usize,
    /// whether the implementation depends on the namespace by which the it is
    /// called. This is used for for intrinsic keywords such as \declare,
    /// \import or \func.
    ns_dependent: bool,
  };
  /// Function defined in Nyarna code.
  pub const Nyarna = struct {
    body: *Expression,
  };

  pub const Data = union(enum) {
    ny: Nyarna,
    ext: External,
  };

  callable: *Type.Callable,
  /// if the function is named, this is the reference to the symbol naming the
  /// function.
  name      : ?*Symbol,
  data      : Data,
  defined_at: Position,
  /// contains the pointer to the function's current stack frame.
  /// referenced by the variables that represent the arguments of the invocation
  /// of this function.
  variables: *VariableContainer,

  pub inline fn sig(self: *const Function) *const Signature {
    return self.callable.sig;
  }

  /// returns the pointer to the first argument in the function's current stack
  /// frame. precondition: function has a stack frame.
  pub fn argStart(self: *const Function) [*]StackItem {
    // arguments are at the *end* of the function's frame
    // (because their variables are generated after those inside the
    // function's body).
    return self.variables.cur_frame.? + 1 + self.variables.num_values -
      self.callable.sig.parameters.len;
  }
};

/// part of any structure that defines variables.
/// variables reference this to access their current value.
pub const VariableContainer = struct {
  /// base pointer from which the variables' values can be accessed via offset.
  cur_frame: ?[*]StackItem = null,
  /// number of values in this frame. This does not necessarily equal the number
  /// of variables since variables can share a slot if their lifetimes to not
  /// overlap.
  num_values: u15,
};

/// the signature of a callable entity.
pub const Signature = struct {
  pub const Parameter = struct {
    pos    : Position,
    name   : []const u8,
    spec   : SpecType,
    capture: enum {default, varargs, borrow},
    default: ?*Expression,
    config : ?BlockConfig,
  };

  parameters  : []Parameter,
  primary     : ?u21,
  varmap      : ?u21,
  auto_swallow: ?struct{
    param_index: usize,
    depth      : usize,
  },
  returns: Type,

  pub fn isKeyword(sig: *const Signature) bool {
    return sig.returns.isNamed(.ast);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Type.Structural.typedef(self);
  }
};


pub const Prototype = enum {
  textual, numeric, @"enum", optional, concat, list, sequence, map, record,
  intersection,
};

pub const Expression = @import("model/Expression.zig");

pub const Value = @import("model/Value.zig");

/// A module represents a loaded file.
pub const Module = struct {
  /// exported symbols
  symbols: []*Symbol,
  /// a module's root is a function that, when called with arguments for the
  /// module's parameters, returns the module's content value. libraries have
  /// no root function.
  root: ?*Function,
  // TODO: schema

  pub fn locator(self: *Module) Locator {
    return self.root.pos.source.locator;
  }
};

/// A document is the final result of loading a main module.
pub const Document = struct {
  root   : *Value,
  globals: *Globals,

  pub fn destroy(self: *Document) void {
    self.globals.destroy();
  }
};