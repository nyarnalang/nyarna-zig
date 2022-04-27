const std = @import("std");
const errors = @import("../errors.zig");
const Reporter = @import("Reporter.zig");
const model = @import("../model.zig");

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

pub fn init(target: std.fs.File) @This() {
  return .{
    .reporter = .{
      .lexerErrorFn = lexerError,
      .parserErrorFn = parserError,
      .previousOccurenceFn = previousOccurence,
      .posChainFn = posChain,
      .wrongItemErrorFn = wrongItemError,
      .scalarErrorFn = scalarError,
      .wrongIdErrorFn = wrongIdError,
      .typeErrorFn = typeError,
      .constructionErrorFn = constructionError,
      .runtimeErrorFn = runtimeError,
      .systemNyErrorFn = systemNyError,
      .fileErrorFn = fileError,
    },
    .writer = target.writer(),
    .do_style = std.os.isatty(target.handle),
  };
}

fn style(
  self: *@This(),
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
  self: *@This(),
  comptime fmt: []const u8,
  args: anytype,
) void {
  self.style(.{.bold, .fg_red}, "[error] ", .{});
  self.style(.{.bold}, fmt, args);
  self.writer.writeByte('\n') catch unreachable;
}

fn renderInfo(
  self: *@This(),
  comptime fmt: []const u8,
  args: anytype,
) void {
  self.style(.{.bold, .fg_white}, "[info] ", .{});
  self.style(.{.bold}, fmt, args);
  self.writer.writeByte('\n') catch unreachable;
}

fn lexerError(
  reporter: *Reporter,
  id: errors.LexerError,
  pos: model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  self.renderError("(lex) {s}", .{@tagName(id)});
}

fn parserError(
  reporter: *Reporter,
  id: errors.GenericParserError,
  pos: model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  self.renderError("(parse) {s}", .{@tagName(id)});
}

fn wrongItemError(
  reporter: *Reporter,
  id: errors.WrongItemError,
  pos: model.Position,
  expected: []const errors.WrongItemError.ItemDescr,
  got: errors.WrongItemError.ItemDescr,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  const arr = errors.WrongItemError.ItemDescr.formatterAll(expected);
  const single = got.formatter();
  switch (id) {
    .ExpectedXGotY => self.renderError(
      "syntax error: expected {?}, got {}", .{arr, single}),
    .MissingToken => {
      const missing = expected[0].formatter();
      self.renderError("inserted missing item: {}", .{missing});
    },
    .PrematureToken => self.renderError(
      "missing token: {?}", .{arr}),
    .IllegalItem => self.renderError(
      "token not allowed here: {} (expected {?})", .{single, arr}),
  }
}

fn scalarError(
  reporter: *Reporter,
  id: errors.ScalarError,
  pos: model.Position,
  repr: []const u8,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  const entity: []const u8 = switch (id) {
    .UnknownFlag           => "unknown flag",
    .UnknownSyntax         => "unknown syntax",
    .UnknownParameter      => "unknown parameter",
    .UnknownSymbol         => "unknown symbol",
    .UnknownField          => "unknown field",
    .UnknownResolver       => "unknown resolver",
    .UnknownUnique         => "unknown unique type",
    .UnknownPrototype      => "unknown prototype",
    .UnknownBuiltin        => "unknown builtin",
    .DoesntHaveConstructor => "unknown constructor of unique type",
    .InvalidNumber         => "invalid number",
    .NumberTooLarge        => "numeric literal has too many digits",
    .TooManyDecimals       => "numeric literal has too many decimal digits",
    .InvalidDecimals       => "not an integer between 0 and 32",
    .FactorMustntBeNegative=> "factor must not be negative",
    .MustHaveDefinedSuffix =>
      "must have one of the defined suffixes (given: no or unknown suffix)",
  };
  self.renderError("{s}: '{s}'", .{entity, repr});
}

fn wrongIdError(
  reporter: *Reporter,
  id: errors.WrongIdError,
  pos: model.Position,
  expected: []const u8,
  got: []const u8,
  defined_at: model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  const kind: []const u8 = switch (id) {
    .WrongCallId => "wrong",
    .SkippingCallId => "skipping"
  };
  self.renderError("{s} id: expected '{s}', got '{s}'", .{kind, expected, got});
  self.writer.print("  {s} command started here\n", .{defined_at})
    catch unreachable;
}

fn previousOccurence(
  reporter: *Reporter,
  id: errors.PreviousOccurenceError,
  repr: []const u8,
  pos: model.Position,
  previous: model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});

  const msg: []const u8 = switch (id) {
    .IsNotANamespaceCharacter   => " is not a namespace character",
    .AlreadyANamespaceCharacter => " is already a namespace character",
    .DuplicateFlag        => " has been seen previously",
    .DuplicateBlockHeader => " can only be given once per definition",
    .IncompatibleFlag     =>  " is incompatible with previously declared flag",
    .DuplicateAutoSwallow =>
      " conflicts with another auto-swallow definition",
    .DuplicateParameterArgument =>
      " has already been given an argument",
    .MissingParameterArgument =>
      " has not been given an argument",
    .DuplicateSymbolName => " hides existing symbol",
    .MissingEndCommand   => " is missing and explict end",
    .CannotAssignToConst => " is constant and cannot be assigned to",
    .DuplicateEnumValue  => " occurs multiple times",
    .MultipleModuleKinds => " has already been set",
    .DuplicateMappingKey => " has been seen previously",
    .DuplicateSuffix     => " is already a suffix",
    .FactorsTooFarApart  => " is too many magnitudes away",
  };

  const entity_name: []const u8 = switch (id) {
    .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character",
    .DuplicateFlag, .IncompatibleFlag => "flag",
    .DuplicateBlockHeader => "block header",
    .DuplicateAutoSwallow => "swallow def",
    .DuplicateParameterArgument, .MissingParameterArgument => "parameter",
    .DuplicateSymbolName => "symbol",
    .MissingEndCommand   => "command",
    .CannotAssignToConst => "variable",
    .DuplicateEnumValue  => "enum value",
    .MultipleModuleKinds => "module kind",
    .DuplicateMappingKey => "key",
    .DuplicateSuffix     => "suffix",
    .FactorsTooFarApart  => "factor",
  };

  const prev_kind: []const u8 = switch (id) {
    .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter, .DuplicateFlag,
    .DuplicateBlockHeader, .DuplicateAutoSwallow => "given",
    .IncompatibleFlag => "other flag",
    .DuplicateParameterArgument => "previous argument",
    .MissingParameterArgument => "parameter definition",
    .DuplicateSymbolName => "symbol definition",
    .MissingEndCommand => "here",
    .CannotAssignToConst => "variable definition",
    .DuplicateEnumValue, .DuplicateMappingKey => "first seen",
    .MultipleModuleKinds => "set",
    .DuplicateSuffix     => "suffix defined",
    .FactorsTooFarApart  => "from this factor",
  };

  self.renderError("{s} '{s}'{s}", .{entity_name, repr, msg});
  self.writer.print("  {s} {s} here\n", .{previous, prev_kind})
    catch unreachable;
}

fn posChain(
  reporter  : *Reporter,
  id        : errors.PositionChainError,
  pos       : model.Position,
  referenced: []model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  self.renderError("{s}", .{@tagName(id)});
  for (referenced) |ref| {
    self.writer.print("  {s} referenced here\n", .{ref}) catch unreachable;
  }
}

fn typeError(
  reporter: *Reporter,
  id      : errors.TypeError,
  types   : []const model.SpecType,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{types[0].pos});
  const main = types[0].t.formatter();
  switch (id) {
    .ExpectedExprOfTypeXGotY => {
      self.renderError("incompatible type: {}", .{main});
      const spec = types[1].t.formatter();
      self.writer.print(
        "  {s} specified type: {}\n", .{types[1].pos, spec}
      ) catch unreachable;
    },
    .ScalarTypesMismatch => {
      self.renderError("incompatible scalar type: {}", .{main});
      const spec = types[1].t.formatter();
      self.writer.print(
        "  {s} specified scalar type: {}\n", .{types[1].pos, spec}
      ) catch unreachable;
    },
    .IncompatibleTypes => {
      self.renderError("type not compatible with previous types: {}", .{main});
      for (types[1..]) |item| {
        const prev = item.t.formatter();
        self.writer.print(
          "  {s} previous type: {}", .{item.pos, prev}
        ) catch unreachable;
      }
    },
    .InvalidInnerConcatType => {
      self.renderError("invalid inner type for Concat: '{}'", .{main});
    },
    .InvalidInnerOptionalType => {
      self.renderError("invalid inner type for Optional: '{}'", .{main});
    },
    .InvalidInnerIntersectionType => {
      self.renderError("invalid inner type for Intersection: '{}'", .{main});
    },
    .InvalidInnerListType => {
      self.renderError("invalid inner type for List: '{}'", .{main});
    },
    .InvalidInnerSequenceType => {
      self.renderError(
        "invalid inner type for Sequence (must be record): '{}'", .{main});
    },
    .InvalidDirectSequenceType => {
      self.renderError("invalid direct type for Sequence: '{}'", .{main});
    },
    .InvalidMappingKeyType => {
      self.renderError("cannot use type as mapping key: '{}'", .{main});
    },
    .NonEmptyAfterNonSequentiable => {
      self.renderError("expression would force a sequence", .{});
      const prev = types[1].t.formatter();
      self.writer.print(
        "  {s} previous expression of type '{}' cannot be part of a sequence",
        .{types[1].pos, prev}) catch unreachable;
    },
    .InvalidDefinitionValue => {
      self.renderError(
        "given value for symbol definition is a {} " ++
        "which cannot be made into a symbol", .{main});
    },
    .CannotBranchOn => {
      self.renderError("cannot branch on expression of type '{}'", .{main});
    },
    .VarmapRequiresMap => {
      self.renderError("`varmap` requires mapping type, got '{}'", .{main});
    },
    .VarargsRequiresList => {
      self.renderError("`varargs` requires list type, got '{}'", .{main});
    },
    .BorrowRequiresRef => {
      self.renderError(
        "`borrow` requires ref type " ++
        "(callable, concat, list, map, record), got '{}'", .{main});
    },
    .TypesNotDisjoint => {
      self.renderError("type is not disjoint: {}", .{main});
      const prev = types[1].t.formatter();
      self.writer.print(
        "  {s} with type: {}\n", .{types[1].pos, prev}
      ) catch unreachable;
    },
    .MultipleScalarTypes => {
      self.renderError("multiple scalar types: {}", .{main});
      const prev = types[1].t.formatter();
      self.writer.print(
        "  {s} previous scalar type: {}\n", .{types[1].pos, prev}
      ) catch unreachable;
    },
  }
}

fn constructionError(
  reporter: *Reporter,
  id: errors.ConstructionError,
  pos: model.Position,
  t: model.Type,
  repr: []const u8,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  const t_fmt = t.formatter();
  switch (id) {
    .NotInEnum => self.renderError(
      "given value '{s}' is not part of enum {}", .{repr, t_fmt}),
    .OutOfRange => self.renderError(
      "given value '{s}' is outside of the range of type {}", .{repr, t_fmt}),
    .TooManyDecimalsForType => self.renderError(
      "given value '{s}' has too many decimal digits for type {}",
      .{repr, t_fmt}),
    .CharacterNotAllowed => self.renderError(
      "character '{s}' is not allowed in type {}", .{repr, t_fmt}),
    .InvalidFloat => self.renderError(
      "cannot parse as {}: '{s}'", .{t_fmt, repr}),
    .MissingSuffix => self.renderError(
      "'{s}' has no suffix, must have one of the suffixes of type {}",
      .{repr, t_fmt}),
    .UnknownSuffix => self.renderError(
      "'{s}' is not a known suffix for type {}", .{repr, t_fmt}),
  }
}

fn runtimeError(
  reporter: *Reporter,
  id: errors.RuntimeError,
  pos: model.Position,
  msg: []const u8,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  switch (id) {
    .IndexError => self.renderError("index error: {s}", .{msg}),
  }
}

fn systemNyError(
  reporter: *Reporter,
  id: errors.SystemNyError,
  pos: model.Position,
  msg: []const u8,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  self.renderError("(system.ny) {s}: {s}", .{@tagName(id), msg});
}

fn fileError(
  reporter: *Reporter,
  id: errors.FileError,
  pos: model.Position,
  path: []const u8,
  message: []const u8,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
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