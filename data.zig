const std = @import("std");

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
/// source file, but some constructs originate elsewhere.
pub const Position = union(enum) {
  /// Construct has no source position since it is intrinsic to the language.
  intrinsic: void,
  /// Construct originates from a module source
  module: struct {
    name: []const u8,
    start: Cursor,
    end: Cursor
  },
  /// Construct originates from an argument to the interpreter.
  argument: struct {
    /// Name of the parameter the argument was bound to.
    param_name: []u8
  },

  /// The invokation position is where the interpreter is called.
  /// This is an singleton, there is only one invokation position.
  invokation: void,

  pub fn inMod(name: []const u8, start: Cursor, end: Cursor) Position {
    return .{.module = .{.name = name, .start = start, .end = end}};
  }

  /// Creates a new position starting at the start of left and ending at the end of right.
  pub fn span(left: Position, right: Position) Position {
    std.debug.assert(left == .module and right == .module);
    std.debug.assert(std.mem.eql(u8, left.module.name, right.module.name));
    return .{.module = .{.name = left.module.name, .start = left.module.start, .end = right.module.end}};
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
      const end = std.mem.indexOfScalar(u8, input[1..], '.') orelse return Error.parse_error;
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
  /// Describes changes in command characters. either before or after may be 0,
  /// but not both. If before is 0, after gets to be a new command character
  /// with an empty namespace.
  /// If after is 0, before is to be a command character that gets disabled.
  /// If neither is 0, the command character before will be disabled and after
  /// will take its place, referring to before's namespace.
  pub const Map = struct {
    pos: Position,
    from: u21,
    to: u21
  };

  pub const SyntaxDef =  struct {
    pos: Position,
    syntax: *SpecialSyntax,
  };

  syntax: ?SyntaxDef,
  map: []Map,
  off_colon: ?Position,
  off_comment: ?Position,
  full_ast: ?Position,
};



pub const Node = struct {
  pub const Literal = struct {
    kind: enum {text, space},
    content: []const u8,

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
  pub const SymRef = union(enum) {
    resolved: *Symbol,
    unresolved: struct {
      ns: u16,
      name: []const u8,
    },
  };
  pub const Access = struct {
    subject: *Node,
    id: []const u8,
  };
  pub const Assignment = struct {
    target: union(enum) {
      unresolved: *Node,
      resolved: *Expression,
    },
    replacement: *Node,
  };
  pub const UnresolvedCall = struct {
    pub const ParamKind = union(enum) {
      named: []const u8,
      direct: []const u8,
      primary,
      position
    };
    pub const Param = struct {
      kind: ParamKind,
      content: *Node,
      /// See doc of first_block_param below.
      had_explicit_block_config: bool,
    };
    target: *Node,
    params: []Param,
    /// This is used when a call's target is resolved *after* the parameters
    /// have been read in. The resolution checks whether any parameter that was
    /// given as block and did not have an explicit block config would have
    /// gotten a default block config – which will then be reported as error.
    first_block_param: usize,
  };
  pub const ResolvedCall = struct {
    target: *Expression,
    args: []*Node,
  };

  pub const Data = union(enum) {
    access: Access,
    assignment: Assignment,
    literal: Literal,
    concatenation: Concatenation,
    paragraphs: Paragraphs,
    symref: SymRef,
    unresolved_call: UnresolvedCall,
    resolved_call: ResolvedCall,
    voidNode,
  };

  pos: Position,
  data: Data,
};

pub const Symbol = struct {
  /// External function, pre-defined by Nyarna or registered via Nyarna's API.
  pub const ExtFunc = struct {
    // TODO
  };
  /// Internal function, defined in Nyarna code.
  pub const NyFunc = struct {
    // TODO
  };
  /// A variable defined in Nyarna code.
  pub const Variable = struct {
    // TODO
  };

  pub const Data = union(enum) {
    ext_func: ExtFunc,
    ny_func: NyFunc,
    variable: Variable
  };

  defined_at: Position,
  name: []const u8,
  data: Data,
};

pub const SpecialSyntax = struct {
  pub const Item = union(enum) {
    literal: []const u8,
    space: []const u8,
    special_char: u21,
    node: *Node,
  };

  push: fn(self: *SpecialSyntax, item: Item) std.mem.Allocator.Error!void,
  finish: fn(self: *SpecialSyntax) std.mem.Allocator.Error!*Node,
};

pub const Signature = struct {
  pub const Parameter = struct {
    pos: Position,
    name: []const u8,
    // TODO: type
    capture: enum {default, varargs},
    default: *Expression,
    config: ?BlockConfig,
    mutable: bool,
  };

  parameter: []Parameter,
  keyword: bool,
  primary: ?u31,
  varmap: ?u31,
  auto_swallow: ?struct{
    param_index: usize,
    depth: usize,
  },
  // TODO: return type
};

pub const Expression = struct {
  pub const Data = union(enum) {
    poison,
  };

  pos: Position,
  data: Data,
};