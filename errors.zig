const std = @import("std");
const model = @import("model.zig");

pub const LexerError = enum {
  UnknownConfigDirective, MissingClosingParenthesis, InvalidUtf8Encoding,
  IllegalCodePoint, IllegalOpeningParenthesis, IllegalBlocksStartInArgs,
  IllegalCommandChar, MixedIndentation, IllegalIndentation,
  IllegalContentAtHeader, IllegalCharacters, InvalidEndCommand,
  SwallowDepthWithoutDiamondClose, InvalidLocator, IllegalColon, IllegalNameSep,
  AssignmentWithoutExpression, MissingId, IllegalContentAfterId,
};

pub const GenericParserError = enum {
  NamedArgumentInAssignment, MissingBlockNameEnd, NonLocationFlag,
  NonDefinitionFlag, BlockHeaderNotAllowedForDefinition, MissingSymbolName,
  MissingSymbolType, MissingSymbolEntity, PrefixedSymbolMustBeCalled,
  AstNodeInNonKeyword, CannotResolveImmediately, InvalidLvalue, CantBeCalled,
  TooManyArguments, UnexpectedPrimaryBlock, InvalidPositionalArgument,
  BlockNeedsConfig, InvalidNamedArgInAssign, UnfinishedCallInTypeArg, NotAType,
  CantCallUnfinished, FailedToCalculateReturnType, FieldAccessWithoutInstance,
  MethodOutsideDeclare, CannotResolveLocator, ImportIllegalInFullast,
  MissingInitialValue, IllegalNumericInterval, EntityCannotBeNamed,
  SurplusFlags,
};

pub const WrongItemError = enum {
  pub const ItemDescr = union(enum) {
    token: model.Token,
    character: u21,
    node,

    pub fn format(
      self: ItemDescr,
      comptime _: []const u8,
      options: std.fmt.FormatOptions,
      writer: anytype
    ) @TypeOf(writer).Error!void {
      switch (self) {
        .token => |t| try writer.writeAll(@tagName(t)),
        .character => |c| {
          try writer.writeByte('\'');
          try std.fmt.formatUnicodeCodepoint(c, options, writer);
          try writer.writeByte('\'');
        },
        .node => try writer.writeAll("<node>"),
      }
    }

    pub fn formatAll(
      data: []const ItemDescr,
      comptime specifier: []const u8,
      options: std.fmt.FormatOptions,
      writer: anytype
    ) @TypeOf(writer).Error!void {
      if ((comptime std.mem.eql(u8, specifier, "?")) and data.len == 1) {
        try data[0].format("", options, writer);
      } else {
        for (data) |cur, index| {
          try if (index == 0) writer.writeByte('{')
          else writer.writeAll(", ");
          try cur.format(specifier, options, writer);
        }
        try writer.writeByte('}');
      }
    }

    pub fn formatter(self: ItemDescr) std.fmt.Formatter(format) {
      return .{.data = self};
    }

    pub fn formatterAll(data: []const ItemDescr) std.fmt.Formatter(formatAll) {
      return .{.data = data};
    }
  };

  ExpectedXGotY, MissingToken, PrematureToken, IllegalItem,
};

pub const UnknownError = enum {
  UnknownFlag, UnknownSyntax, UnknownParameter, UnknownSymbol, UnknownField,
  UnknownResolver,
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
  IsNotANamespaceCharacter, AlreadyANamespaceCharacter, DuplicateFlag,
  DuplicateBlockHeader, IncompatibleFlag, DuplicateAutoSwallow,
  DuplicateParameterArgument, MissingParameterArgument, DuplicateSymbolName,
  MultipleScalarTypesInIntersection, MissingEndCommand, CannotAssignToConst,

  fn errorMsg(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter => " is not a namespace character",
      .AlreadyANamespaceCharacter => " is already a namespace character",
      .DuplicateFlag => " has been seen previously",
      .DuplicateBlockHeader => " can only be given once per definition",
      .IncompatibleFlag =>  " is incompatible with previously declared flag",
      .DuplicateAutoSwallow =>
        " conflicts with another auto-swallow definition",
      .DuplicateParameterArgument =>
        " has already been given an argument",
      .MissingParameterArgument =>
        " has not been given an argument",
      .DuplicateSymbolName => " hides existing symbol",
      .MultipleScalarTypesInIntersection =>
        " conflicts with another scalar type",
      .MissingEndCommand => " is missing and explict end",
      .CannotAssignToConst => " is constant and cannot be assigned to",
    };
  }

  fn entityName(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character",
      .DuplicateFlag, .IncompatibleFlag => "flag",
      .DuplicateBlockHeader => "block header",
      .DuplicateAutoSwallow => "swallow def",
      .DuplicateParameterArgument, .MissingParameterArgument => "parameter",
      .DuplicateSymbolName => "symbol",
      .MultipleScalarTypesInIntersection => "type",
      .MissingEndCommand => "command",
      .CannotAssignToConst => "variable",
    };
  }

  fn prevOccurenceKind(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter, .DuplicateFlag,
      .DuplicateBlockHeader, .DuplicateAutoSwallow => "given",
      .IncompatibleFlag => "other flag",
      .DuplicateParameterArgument => "previous argument",
      .MissingParameterArgument => "parameter definition",
      .DuplicateSymbolName => "symbol definition",
      .MultipleScalarTypesInIntersection => "previous type",
      .MissingEndCommand => "here",
      .CannotAssignToConst => "variable definition",
    };
  }
};

pub const PositionChainError = enum {
  /// emitted when types in \declare reference each other in a chain that
  /// cannot be made into a set of types.
  CircularType,
};

pub const WrongTypeError = enum {
   /// gives two types: first expected, then actual type.
   ExpectedExprOfTypeXGotY,
   /// gives two scalar types: first expected, then actual type.
   ScalarTypesMismatch,
   /// gives at least two types: the first type is the one that makes the set
   /// incompatible, the others are other types in the set.
   IncompatibleTypes,
   /// gives one type.
   InvalidInnerConcatType,
   /// gives one type.
   InvalidInnerOptionalType,
   /// gives one type.
   InvalidInnerIntersectionType,
   /// gives one type.
   InvalidDefinitionValue,
};

pub const ConstructionError = enum {
  NotInEnum, OutOfRange, TooManyDecimals, NotANumber, NumberTooLarge,
};

pub const FileError = enum {
  FailedToOpen, NotAFile, FailedToRead,
};

pub const Reporter = struct {
  lexerErrorFn: fn(
    reporter: *Reporter,
    id: LexerError,
    pos: model.Position,
  ) void,
  parserErrorFn: fn(
    reporter: *Reporter,
    id: GenericParserError,
    pos: model.Position,
  ) void,
  wrongItemErrorFn: fn(
    reporter: *Reporter,
    id: WrongItemError,
    pos: model.Position,
    expected: []const WrongItemError.ItemDescr,
    got: WrongItemError.ItemDescr,
  ) void,
  unknownErrorFn: fn(
    reporter: *Reporter,
    id: UnknownError,
    pos: model.Position,
    name: []const u8,
  ) void,
  wrongIdErrorFn: fn(
    reporter: *Reporter,
    id: WrongIdError,
    pos: model.Position,
    expected: []const u8,
    got: []const u8,
    defined_at: model.Position,
  ) void,
  previousOccurenceFn: fn(
    reporter: *Reporter,
    id: PreviousOccurenceError,
    repr: []const u8,
    pos: model.Position,
    previous: model.Position,
  ) void,
  posChainFn: fn(
    reporter: *Reporter,
    id: PositionChainError,
    pos: model.Position,
    references: []model.Position,
  ) void,
  wrongTypeErrorFn: fn(
    reporter: *Reporter,
    id: WrongTypeError,
    pos: model.Position,
    types: []const model.Type,
  ) void,
  constructionErrorFn: fn(
    reporter: *Reporter,
    id: ConstructionError,
    pos: model.Position,
    t: model.Type,
    repr: []const u8,
  ) void,
  fileErrorFn: fn(
    reporter: *Reporter,
    id: FileError,
    pos: model.Position,
    path: []const u8,
    message: []const u8,
  ) void,
};

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
        .posChainFn = CmdLineReporter.posChain,
        .wrongItemErrorFn = CmdLineReporter.wrongItemError,
        .unknownErrorFn = CmdLineReporter.unknownError,
        .wrongIdErrorFn = CmdLineReporter.wrongIdError,
        .wrongTypeErrorFn = CmdLineReporter.wrongTypeError,
        .constructionErrorFn = CmdLineReporter.constructionError,
        .fileErrorFn = CmdLineReporter.fileError,
      },
      .writer = stdout.writer(),
      .do_style = std.os.isatty(stdout.handle),
    };
  }

  fn style(
    self: *CmdLineReporter,
    styles: anytype,
    comptime fmt: []const u8,
    args: anytype,
  ) void {
    if (self.do_style) {
      inline for (styles) |s| {
        self.writer.print("\x1b[{}m", .{@enumToInt(@as(Style, s))})
          catch unreachable;
      }
    }
    self.writer.print(fmt, args) catch unreachable;
    if (self.do_style) self.writer.writeAll("\x1b[m") catch unreachable;
  }

  fn renderError(
    self: *CmdLineReporter,
    comptime fmt: []const u8,
    args: anytype,
  ) void {
    self.style(.{.bold, .fg_red}, "[error] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn renderInfo(
    self: *CmdLineReporter,
    comptime fmt: []const u8,
    args: anytype,
  ) void {
    self.style(.{.bold, .fg_white}, "[info] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn lexerError(reporter: *Reporter, id: LexerError, pos: model.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    self.renderError("(lex) {s}", .{@tagName(id)});
  }

  fn parserError(
    reporter: *Reporter,
    id: GenericParserError,
    pos: model.Position,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    self.renderError("(parse) {s}", .{@tagName(id)});
  }

  fn wrongItemError(
    reporter: *Reporter,
    _: WrongItemError, // TODO
    pos: model.Position,
    expected: []const WrongItemError.ItemDescr,
    got: WrongItemError.ItemDescr,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    const arr = WrongItemError.ItemDescr.formatterAll(expected);
    const single = got.formatter();
    self.renderError("wrong token: expected {?}, got {}", .{arr, single});
  }

  fn unknownError(
    reporter: *Reporter,
    id: UnknownError,
    pos: model.Position,
    name: []const u8,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    const entity: []const u8 = switch (id) {
      .UnknownFlag      => "flag",      .UnknownSyntax   => "syntax",
      .UnknownParameter => "parameter", .UnknownSymbol   => "symbol",
      .UnknownField     => "field",     .UnknownResolver => "resolver",
    };
    self.renderError("unknown {s}: '{s}'", .{entity, name});
  }

  fn wrongIdError(
    reporter: *Reporter,
    id: WrongIdError,
    pos: model.Position,
    expected: []const u8,
    got: []const u8,
    defined_at: model.Position,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    self.renderError("{s} id: expected '{s}', got '{s}'",
        .{WrongIdError.kind(id), expected, got});
    self.writer.print("{s}", .{defined_at}) catch unreachable;
    _ = self.writer.write("command started here") catch unreachable;
  }

  fn previousOccurence(
    reporter: *Reporter,
    id: PreviousOccurenceError,
    repr: []const u8,
    pos: model.Position,
    previous: model.Position,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    self.renderError("{s} '{s}'{s}", .{id.entityName(), repr, id.errorMsg()});
    self.writer.print("{s}", .{previous}) catch unreachable;
    self.writer.print("{s} here\n", .{id.prevOccurenceKind()})
      catch unreachable;
  }

  fn posChain(
    reporter: *Reporter,
    id: PositionChainError,
    pos: model.Position,
    referenced: []model.Position,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    self.renderError("{s}", .{@tagName(id)});
    for (referenced) |ref| {
      self.writer.print("  {s} referenced here\n", .{ref}) catch unreachable;
    }
  }

  fn wrongTypeError(
    reporter: *Reporter,
    id: WrongTypeError,
    pos: model.Position,
    types: []const model.Type,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    switch (id) {
      .ExpectedExprOfTypeXGotY => {
        const t1 = types[0].formatter();
        const t2 = types[1].formatter();
        self.renderError(
          "expression has incompatible type: expected '{}', got '{}'", .{
          t1, t2});
      },
      .ScalarTypesMismatch => {
        const t1 = types[0].formatter();
        const t2 = types[1].formatter();
        self.renderError("expected scalar type '{}', got '{}'", .{t1, t2});
      },
      .IncompatibleTypes => {
        const main = types[0].formatter();
        const others = model.Type.formatterAll(types[1..]);
        self.renderError(
          "expression type '{}' is not compatible with previous types {}", .{
          main, others});
      },
      .InvalidInnerConcatType => {
        const t_fmt = types[0].formatter();
        self.renderError("invalid inner type for Concat: '{}'", .{t_fmt});
      },
      .InvalidInnerOptionalType => {
        const t_fmt = types[0].formatter();
        self.renderError("invalid inner type for Optional: '{}'", .{t_fmt});
      },
      .InvalidInnerIntersectionType => {
        const t_fmt = types[0].formatter();
        self.renderError("invalid inner type for Intersection: '{}'", .{t_fmt});
      },
      .InvalidDefinitionValue => {
        const t_fmt = types[0].formatter();
        self.renderError(
          "given value for symbol definition is '{}' " ++
          "which cannot be made into a symbol", .{t_fmt});
      },
    }
  }

  fn constructionError(
    reporter: *Reporter,
    id: ConstructionError,
    pos: model.Position,
    t: model.Type,
    repr: []const u8,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    const t_fmt = t.formatter();
    switch (id) {
      .NotInEnum => self.renderError(
        "given value '{s}' is not part of enum {}", .{repr, t_fmt}),
      .OutOfRange => self.renderError(
        "given value '{s}' is outside of the range of type {}", .{repr, t_fmt}),
      .TooManyDecimals => self.renderError(
        "given value '{s}' has too many decimal digits for type {}",
        .{repr, t_fmt}),
      .NotANumber => self.renderError(
        "given value '{s}' cannot be read as number.", .{repr}),
      .NumberTooLarge => self.renderError(
        "number '{s}' is too large.", .{repr}),
    }
  }

  fn fileError(
    reporter: *Reporter,
    id: FileError,
    pos: model.Position,
    path: []const u8,
    message: []const u8,
  ) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.style(.{.bold}, "{s}", .{pos});
    switch (id) {
      .FailedToOpen =>
        self.renderError("cannot open {s}: {s}", .{path, message}),
      .NotAFile =>
        self.renderError("{s} is not a file, but a {s}", .{path, message}),
      .FailedToRead =>
        self.renderError("failed to read content of file {s}: {s}",
                         .{path, message}),
    }
  }
};