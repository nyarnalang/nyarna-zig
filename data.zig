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

  pub fn posHere(c: Cursor, name: []const u8) Position {
    return Position{
      .module = .{
        .name = name, .start = c, .end = c,
      }
    };
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
  /// Describes changes in command characters. either .from or .to may be 0,
  /// but not both. If .from is 0, .to gets to be a new command character
  /// with an empty namespace.
  /// If .to is 0, .from is to be a command character that gets disabled.
  /// If neither is 0, the command character .from will be disabled and .to
  /// will take its place, referring to .from's namespace.
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

  pub fn empty() BlockConfig {
    return .{
      .syntax = null, .map = &.{}, .off_colon = null, .off_comment = null, .full_ast = null
    };
  }
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
      ns: u15,
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

pub const Expression = struct {
  pub const Data = union(enum) {
    poison,
  };

  pos: Position,
  data: Data,
};