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

pub const BlockConfig = struct {
  /// Describes changes in command characters. either before or after may be 0,
  /// but not both. If before is 0, after gets to be a new command character
  /// with an empty namespace.
  /// If after is 0, before is to be a command character that gets disabled.
  /// If neither is 0, the command character before will be disabled and after
  /// will take its place, referring to before's namespace.
  pub const CharChange = struct {
    before: u21,
    after: u21,
  };

  /// Lists all command character changes mandated by this block config.
  map: ?[]CharChange,
  /// whether `off #` has been given.
  commentOff: bool,
  /// whether `off :` has been given.
  colonOff: bool,
  /// whether `fullast` has been given.
  fullAst: bool,
  /// contains the syntax name given, if any.
  syntax: ?[]u8,
};

pub const Node = struct {
  pub const Literal = struct {
    kind: enum {text, space},
    content: []const u8,

  };
  pub const Concatenation = struct {
    content: []Node,
  };
  pub const Paragraphs = struct {
    content: []Node,
    /// separators[i] == num linebreaks in separator after item i
    separators: []usize,
  };

  pub const Data = union(enum) {
    literal: Literal,
    concatenation: Concatenation,
    paragraphs: Paragraphs,
    voidNode,
  };

  pos: Position,
  data: Data,
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