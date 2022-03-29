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
      .wrongTypeErrorFn = wrongTypeError,
      .constructionErrorFn = constructionError,
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
    .DuplicateEnumValue => " occurs multiple times",
    .MultipleModuleKinds => " has already been set",
  };

  const entity_name: []const u8 = switch (id) {
    .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character",
    .DuplicateFlag, .IncompatibleFlag => "flag",
    .DuplicateBlockHeader => "block header",
    .DuplicateAutoSwallow => "swallow def",
    .DuplicateParameterArgument, .MissingParameterArgument => "parameter",
    .DuplicateSymbolName => "symbol",
    .MultipleScalarTypesInIntersection => "type",
    .MissingEndCommand => "command",
    .CannotAssignToConst => "variable",
    .DuplicateEnumValue => "enum value",
    .MultipleModuleKinds => "module kind",
  };

  const prev_kind: []const u8 = switch (id) {
    .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter, .DuplicateFlag,
    .DuplicateBlockHeader, .DuplicateAutoSwallow => "given",
    .IncompatibleFlag => "other flag",
    .DuplicateParameterArgument => "previous argument",
    .MissingParameterArgument => "parameter definition",
    .DuplicateSymbolName => "symbol definition",
    .MultipleScalarTypesInIntersection => "previous type",
    .MissingEndCommand => "here",
    .CannotAssignToConst => "variable definition",
    .DuplicateEnumValue => "first seen",
    .MultipleModuleKinds => "set",
  };

  self.renderError("{s} '{s}'{s}", .{entity_name, repr, msg});
  self.writer.print("  {s} {s} here\n", .{previous, prev_kind})
    catch unreachable;
}

fn posChain(
  reporter: *Reporter,
  id: errors.PositionChainError,
  pos: model.Position,
  referenced: []model.Position,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
  self.style(.{.bold}, "{s}", .{pos});
  self.renderError("{s}", .{@tagName(id)});
  for (referenced) |ref| {
    self.writer.print("  {s} referenced here\n", .{ref}) catch unreachable;
  }
}

fn wrongTypeError(
  reporter: *Reporter,
  id: errors.WrongTypeError,
  pos: model.Position,
  types: []const model.Type,
) void {
  const self = @fieldParentPtr(@This(), "reporter", reporter);
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
    .InvalidInnerListType => {
      const t_fmt = types[0].formatter();
      self.renderError("invalid inner type for List: '{}'", .{t_fmt});
    },
    .InvalidDefinitionValue => {
      const t_fmt = types[0].formatter();
      self.renderError(
        "given value for symbol definition is '{}' " ++
        "which cannot be made into a symbol", .{t_fmt});
    },
    .CannotBranchOn => {
      const t_fmt = types[0].formatter();
      self.renderError("cannot branch on expression of type '{}'", .{t_fmt});
    },
    .VarmapRequiresMap => {
      const t_fmt = types[0].formatter();
      self.renderError("`varmap` requires mapping type, got '{}'", .{t_fmt});
    },
    .VarargsRequiresList => {
      const t_fmt = types[0].formatter();
      self.renderError("`varargs` requires list type, got '{}'", .{t_fmt});
    },
    .BorrowRequiresRef => {
      const t_fmt = types[0].formatter();
      self.renderError(
        "`borrow` requires ref type " ++
        "(callable, concat, list, map, record), got '{}'", .{t_fmt});
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