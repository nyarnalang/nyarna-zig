

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

  pub fn in_mod(name: []const u8, start: Cursor, end: Cursor) Cursor {
    return .{.module = .{.name = name, .start = start, .end = end}};
  }
};

