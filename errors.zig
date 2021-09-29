const std = @import("std");
const data = @import("data");

pub const LexerError = enum {
  UnknownConfigDirective, MissingClosingParenthesis, InvalidUtf8Encoding,
  IllegalCodePoint, IllegalOpeningParenthesis, IllegalBlocksStartInArgs,
  IllegalCommandChar, MixedIndentation, IllegalIndentation, IllegalContentAtHeader,
  IllegalCharacterForId, InvalidEndCommand, SwallowDepthWithoutDiamondClose,
};

pub const GenericParserError = enum {
  NamedArgumentInAssignment, MissingBlockNameEnd, UnknownFlag,
  NonLocationFlag, NonDefinitionFlag, BlockHeaderNotAllowedForDefinition,
  MissingSymbolName, MissingSymbolType, MissingSymbolEntity, UnknownSyntax,
  PrefixedFunctionMustBeCalled
};

pub const WrongItemError = enum {
  pub const ItemDescr = union(enum) {
    token: data.Token,
    character: u21,
    node
  };

  ExpectedXGotY, MissingToken, PrematureToken, IllegalItem
};

pub const WrongIdError = enum {
  WrongCallId, SkippingCallId,

  fn kind(e: WrongIdError) []const u8 {
    return switch (e) {
      .WrongCallId => "wrong",
      .SkippingCallId => "skipping"
    };
  }
};

pub const PreviousOccurenceError = enum {
  IsNotANamespaceCharacter, AlreadyANamespaceCharacter, DuplicateFlag, DuplicateBlockHeader,

  fn errorMsg(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter => " is not a namespace character",
      .AlreadyANamespaceCharacter => " is already a namespace character",
      .DuplicateFlag => " has been seen previously",
      .DuplicateBlockHeader => " can only be given once per definition",
    };
  }

  fn entityName(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character",
      .DuplicateFlag => "flag",
      .DuplicateBlockHeader => "block header"
    };
  }

  fn prevOccurenceKind(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter, .DuplicateFlag,
      .DuplicateBlockHeader => "given"
    };
  }
};

pub const WrongTypeError = enum {
   ExpectedExprOfTypeXGotY,

  fn errorMsg(e: WrongTypeError) []const u8 {
    return switch (e) {
      .ExpectedExprOfTypeXGotY => "expression has incompatible type",
    };
  }
};

pub const Reporter = struct {
  lexerErrorFn: fn(reporter: *Reporter, id: LexerError, pos: data.Position.Input) void,
  parserErrorFn: fn(reporter: *Reporter, id: GenericParserError, pos: data.Position.Input) void,
  wrongItemErrorFn: fn(reporter: *Reporter, id: WrongItemError, pos: data.Position.Input,
                       expected: []const WrongItemError.ItemDescr, got: WrongItemError.ItemDescr) void,
  wrongIdErrorFn: fn(reporter: *Reporter, id: WrongIdError, pos: data.Position.Input, expected: []const u8, got: []const u8, defined_at: data.Position.Input) void,
  previousOccurenceFn: fn(reporter: *Reporter, id: PreviousOccurenceError, repr: []const u8, pos: data.Position.Input, previous: data.Position.Input) void,
  wrongTypeErrorFn: fn(reporter: *Reporter, id: WrongTypeError, pos: data.Position.Input, expected: data.Type, got: data.Type) void,
};

fn formatItemDescr(d: WrongItemError.ItemDescr, comptime fmt: []const u8,
                   options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
  switch (d) {
    .token => |t| try writer.writeAll(@tagName(t)),
    .character => |c| {
      try writer.writeByte('\'');
      try std.fmt.formatUnicodeCodepoint(c, options, writer);
      try writer.writeByte('\'');
    },
    .node => try writer.writeAll("<node>"),
  }
}

fn formatItemArr(i: []const WrongItemError.ItemDescr, comptime fmt: []const u8,
                 options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
  if (i.len == 1) try formatItemDescr(i[0], fmt, options, writer)
  else {
    for (i) |cur, index| {
      try if (index == 0) writer.writeByte('[')
      else writer.writeAll(", ");
      try formatItemDescr(cur, fmt, options, writer);
    }
    try writer.writeByte(']');
  }
}

fn formatParameterizedType(comptime fmt: []const u8, options: std.fmt.FormatOptions,
                           name: []const u8, inners: []const data.Type,
                           writer: anytype) @TypeOf(writer).Error!void {
  try writer.writeAll(name);
  try writer.writeByte('<');
  for (inners) |inner, index| {
    if (index > 0) {
      try writer.writeAll(", ");
    }
    try formatType(inner, fmt, options, writer);
  }
  try writer.writeByte('>');
}

fn formatType(t: data.Type, comptime fmt: []const u8,
              options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
  switch (t) {
    .intrinsic => |it| try writer.writeAll(@tagName(it)),
    .structural => |struc| try switch (struc.*) {
      .optional => |op|
        formatParameterizedType(fmt, options, "Optional", &[_]data.Type{op.inner}, writer),
      .concat => |con|
        formatParameterizedType(fmt, options, "Concat", &[_]data.Type{con.inner}, writer),
      .paragraphs => |para|
        formatParameterizedType(fmt, options, "Paragraphs", para.inner, writer),
      .list => |list|
        formatParameterizedType(fmt, options, "List", &[_]data.Type{list.inner}, writer),
      .map => |map|
        formatParameterizedType(fmt, options, "Optional", &[_]data.Type{map.key, map.value}, writer),
      .callable => |sig| unreachable,
      .callable_type => writer.writeAll("Type"),
      .intersection => |inter| {
        try writer.writeByte('{');
        if (inter.scalar) |scalar| try formatType(scalar, fmt, options, writer);
        for (inter.types) |inner, i| {
          if (i > 0 or inter.scalar != null) try writer.writeAll(", ");
          try formatType(inner, fmt, options, writer);
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

pub const CmdLineReporter = struct {
  const Style = enum(u8) {
    reset = 0,
    bold = 1,
    underline = 4,
    fg_black = 30,
    fg_red = 31,
    fg_green = 32,
    fg_yellow = 33,
    fg_blue = 34,
    fg_magenta = 35,
    fg_cyan = 36,
    fg_white = 37,
  };

  reporter: Reporter,
  writer: std.fs.File.Writer,
  do_style: bool,

  pub fn init() CmdLineReporter {
    var stdout = std.io.getStdOut();
    return .{
      .reporter = .{
        .lexerErrorFn = CmdLineReporter.lexerError,
        .parserErrorFn = CmdLineReporter.parserError,
        .previousOccurenceFn = CmdLineReporter.previousOccurence,
        .wrongItemErrorFn = CmdLineReporter.wrongItemError,
        .wrongIdErrorFn = CmdLineReporter.wrongIdError,
        .wrongTypeErrorFn = CmdLineReporter.wrongTypeError,
      },
      .writer = stdout.writer(),
      .do_style = std.os.isatty(stdout.handle),
    };
  }

  fn style(self: *CmdLineReporter, styles: anytype, comptime fmt: []const u8, args: anytype) void {
    if (self.do_style) {
      inline for (styles) |s| {
        self.writer.print("\x1b[{}m", .{@enumToInt(@as(Style, s))}) catch unreachable;
      }
    }
    self.writer.print(fmt, args) catch unreachable;
    if (self.do_style) self.writer.writeAll("\x1b[m") catch unreachable;
  }

  fn renderPos(self: *CmdLineReporter, styles: anytype, pos: data.Position.Input) void {
    if (pos.source.argument)
      self.style(styles, "arg \"{s}\"({}:{}): ", .{pos.source.name, pos.start.at_line, pos.start.before_column})
    else
      self.style(styles, "{s}({}:{}): ", .{pos.source.name, pos.start.at_line, pos.start.before_column});
  }

  fn renderError(self: *CmdLineReporter, comptime fmt: []const u8, args: anytype) void {
    self.style(.{.bold, .fg_red}, "[error] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn renderInfo(self: *CmdLineReporter, comptime fmt: []const u8, args: anytype) void {
    self.style(.{.bold, .fg_white}, "[info] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn lexerError(reporter: *Reporter, id: LexerError, pos: data.Position.Input) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    self.renderError("(lex) {s}", .{@tagName(id)});
  }

  fn parserError(reporter: *Reporter, id: GenericParserError, pos: data.Position.Input) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    self.renderError("(parse) {s}", .{@tagName(id)});
  }

  fn wrongItemError(reporter: *Reporter, id: WrongItemError, pos: data.Position.Input,
                    expected: []const WrongItemError.ItemDescr, got: WrongItemError.ItemDescr) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    const arr = std.fmt.Formatter(formatItemArr){.data = expected};
    const single = std.fmt.Formatter(formatItemDescr){.data = got};
    self.renderError("wrong token: expected {}, got {}", .{arr, single});
  }

  fn wrongIdError(reporter: *Reporter, id: WrongIdError, pos: data.Position.Input,
                  expected: []const u8, got: []const u8, defined_at: data.Position.Input) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    self.renderError("{s} id: expected '{s}', got '{s}'",
        .{WrongIdError.kind(id), expected, got});
    self.renderPos(.{}, defined_at);
    _ = self.writer.write("command started here") catch unreachable;
  }

  fn previousOccurence(reporter: *Reporter, id: PreviousOccurenceError, repr: []const u8,
                       pos: data.Position.Input, previous: data.Position.Input) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    self.renderError("{s} '{s}'{s}", .{id.entityName(), repr, id.errorMsg()});
    self.renderPos(.{}, previous);
    self.writer.print("{s} here\n", .{id.prevOccurenceKind()}) catch unreachable;
  }

  fn wrongTypeError(reporter: *Reporter, id: WrongTypeError, pos: data.Position.Input,
                    expected: data.Type, got: data.Type) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(.{.bold}, pos);
    // TODO: for unknown reasons, the compiler crashes when using id.errorMsg() here.
    // this needs to be fixed in the compiler.
    const name = "expression has incompatible type";
    self.renderError("{s}: expected '{}', got '{}'", .{
      name, std.fmt.Formatter(formatType){.data = expected},
      std.fmt.Formatter(formatType){.data = got},
    });
  }
};